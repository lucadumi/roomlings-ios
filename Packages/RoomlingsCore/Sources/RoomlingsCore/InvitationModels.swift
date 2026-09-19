import Foundation

public struct AccountInvitationCode: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init(_ input: String) throws {
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.contains("://") {
            guard !code.contains("\\"),
                  code.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  let link = URLComponents(string: code),
                  ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
                  link.host?.isEmpty == false, link.url != nil,
                  link.user == nil, link.password == nil,
                  let fragment = link.percentEncodedFragment else {
                throw AccountError.invalidInput(.invitationCode)
            }
            var parameters = URLComponents()
            // Match the web's URLSearchParams without opening the invitation's URL.
            parameters.percentEncodedQuery = fragment.replacingOccurrences(of: "+", with: "%20")
            let codes = parameters.queryItems?.filter { $0.name == "account-invite" } ?? []
            guard codes.count == 1, let value = codes.first?.value else {
                throw AccountError.invalidInput(.invitationCode)
            }
            code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard AccountValidation.matches(code, #"^roomlings-invite-[A-Za-z0-9_-]{43}$"#) else {
            throw AccountError.invalidInput(.invitationCode)
        }
        value = code
    }

    public init(link: URL, origin: APIConfiguration) throws {
        guard origin.contains(link) else { throw AccountError.invalidInput(.invitationCode) }
        try self.init(link.absoluteString)
    }

    public func link(origin: APIConfiguration) throws -> URL {
        var components = URLComponents(url: origin.origin, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.fragment = "account-invite=\(value)"
        guard let url = components?.url else { throw AccountError.invalidOrigin }
        return url
    }

    public var description: String { "AccountInvitationCode([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct HouseholdInvitation: Sendable, Decodable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let revokedAt: Date?
    public let uses: Int64

    public init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        id = try fields.uuid("id")
        guard let created = AccountValidation.instant(try fields.string("createdAt")),
              let expires = AccountValidation.instant(try fields.string("expiresAt")),
              expires > created else { throw AccountError.invalidResponse }
        createdAt = created
        expiresAt = expires
        if let revoked = try fields.nullableString("revokedAt") {
            guard let date = AccountValidation.instant(revoked), date >= created else {
                throw AccountError.invalidResponse
            }
            revokedAt = date
        } else {
            revokedAt = nil
        }
        uses = try fields.integer("uses")
    }

    public func isPending(at date: Date = .now) -> Bool {
        revokedAt == nil && expiresAt > date
    }
}

public struct HouseholdInvitationAccess: Sendable, Decodable, Equatable {
    public let household: HouseholdSnapshot
    public let memberID: UUID
    public let role: AccountRole
    public let invitations: [HouseholdInvitation]

    private enum CodingKeys: String, CodingKey {
        case household, role, invitations, accessToken
        case memberID = "memberId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        household = try container.decode(HouseholdSnapshot.self, forKey: .household)
        memberID = try container.decode(UUID.self, forKey: .memberID)
        role = try container.decode(AccountRole.self, forKey: .role)
        invitations = try container.decode([HouseholdInvitation].self, forKey: .invitations)
        let members = try HouseholdMember.projection(household.value)
        guard members.contains(where: { $0.id == memberID && !$0.inactive }),
              Set(invitations.map(\.id)).count == invitations.count,
              role == .owner || invitations.isEmpty else { throw AccountError.invalidResponse }
    }
}

public struct CreatedHouseholdInvitation: Sendable, Decodable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let code: AccountInvitationCode
    public let invitation: HouseholdInvitation
    public let access: HouseholdInvitationAccess

    private enum CodingKeys: String, CodingKey { case code, invitation, access, accessToken }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        let rawCode = try container.decode(String.self, forKey: .code)
        code = try AccountInvitationCode(rawCode)
        guard rawCode == code.value else { throw AccountError.invalidResponse }
        invitation = try container.decode(HouseholdInvitation.self, forKey: .invitation)
        access = try container.decode(HouseholdInvitationAccess.self, forKey: .access)
        guard access.role == .owner, invitation.revokedAt == nil, invitation.uses == 0,
              access.invitations.contains(invitation) else { throw AccountError.invalidResponse }
    }

    public var description: String { "CreatedHouseholdInvitation(id: \(invitation.id))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": invitation.id]) }
}

protocol HouseholdInvitationResponse: Sendable {
    var access: HouseholdInvitationAccess { get }
}

extension HouseholdInvitationAccess: HouseholdInvitationResponse {
    var access: HouseholdInvitationAccess { self }
}

extension CreatedHouseholdInvitation: HouseholdInvitationResponse {}
