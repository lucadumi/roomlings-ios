import Foundation

public enum AccountRole: String, Sendable, Codable {
    case owner, admin, member
}

public enum HouseholdCurrency: String, Sendable, Codable {
    case eur = "EUR"
    case usd = "USD"
    case gbp = "GBP"
    case ron = "RON"
}

public struct Account: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let email: String
    public let name: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, email, name, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        guard let email = AccountValidation.email(try container.decode(String.self, forKey: .email)) else {
            throw AccountError.invalidResponse
        }
        self.email = email
        name = try container.name(forKey: .name)
        createdAt = try container.timestamp(forKey: .createdAt)
    }
}

public struct AccountMembership: Sendable, Codable, Equatable {
    public let householdID: UUID
    public let householdName: String
    public let memberID: UUID
    public let currency: HouseholdCurrency
    public let role: AccountRole

    private enum CodingKeys: String, CodingKey {
        case householdID = "householdId"
        case householdName
        case memberID = "memberId"
        case currency, role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        householdID = try container.decode(UUID.self, forKey: .householdID)
        householdName = try container.name(forKey: .householdName)
        memberID = try container.decode(UUID.self, forKey: .memberID)
        currency = try container.decode(HouseholdCurrency.self, forKey: .currency)
        role = try container.decode(AccountRole.self, forKey: .role)
    }
}

public struct AccountDevice: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let createdAt: String
    public let lastUsedAt: String
    public let expiresAt: String
    public let current: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, createdAt, lastUsedAt, expiresAt, current
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.name(forKey: .label)
        createdAt = try container.timestamp(forKey: .createdAt)
        lastUsedAt = try container.timestamp(forKey: .lastUsedAt)
        expiresAt = try container.timestamp(forKey: .expiresAt)
        current = try container.decode(Bool.self, forKey: .current)
    }
}

/// Retains the server's household without defaults or local ledger calculations.
/// Only envelope, identity and collection shapes are validated here, not the full shared domain.
public struct HouseholdSnapshot: Sendable, Codable, Equatable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let name: String
    public let version: Int64
    public let currency: HouseholdCurrency
    public let value: JSONValue
    let memberIDs: Set<UUID>

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value,
              let idString = object["id"]?.stringValue, let id = UUID(uuidString: idString),
              let rawName = object["name"]?.stringValue, let name = AccountValidation.name(rawName),
              let version = object["version"]?.integerValue, (0...9_007_199_254_740_991).contains(version),
              let rawCurrency = object["currency"]?.stringValue,
              let currency = HouseholdCurrency(rawValue: rawCurrency),
              let budget = object["budget"]?.integerValue, (1...100_000_000).contains(budget),
              object["inviteCode"]?.stringValue != nil,
              let members = object["members"]?.arrayValue, (1...200).contains(members.count),
              object["expenses"]?.arrayValue != nil,
              object["settlements"]?.arrayValue != nil else {
            throw AccountError.invalidResponse
        }
        var memberIDs = Set<UUID>()
        for member in members {
            guard let rawID = member["id"]?.stringValue, let memberID = UUID(uuidString: rawID),
                  let memberName = member["name"]?.stringValue, AccountValidation.name(memberName) != nil,
                  member["color"]?.stringValue != nil,
                  memberIDs.insert(memberID).inserted else { throw AccountError.invalidResponse }
            if let inactive = member["inactive"], case .bool = inactive {
                continue
            } else if member["inactive"] != nil {
                throw AccountError.invalidResponse
            }
        }
        for key in ["bills", "roomComponents", "mutationReceipts"] {
            if let collection = object[key], collection.arrayValue == nil { throw AccountError.invalidResponse }
        }
        for (key, children) in [("shopping", ["items", "runs"]), ("chores", ["items", "history"])] {
            if let collection = object[key] {
                guard case .object = collection,
                      children.allSatisfy({ collection[$0]?.arrayValue != nil }) else {
                    throw AccountError.invalidResponse
                }
            }
        }
        self.id = id
        self.name = name
        self.version = version
        self.currency = currency
        self.value = value
        self.memberIDs = memberIDs
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    public var description: String { "HouseholdSnapshot(id: \(id), version: \(version))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "version": version]) }
}

public struct AccountKitchenSession: Sendable, Codable, Equatable {
    public let memberID: UUID
    public let household: HouseholdSnapshot

    private enum CodingKeys: String, CodingKey {
        case token, household
        case memberID = "memberId"
    }

    fileprivate init(memberID: UUID, household: HouseholdSnapshot) {
        self.memberID = memberID
        self.household = household
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.token), try container.decodeNil(forKey: .token) else {
            throw AccountError.invalidResponse
        }
        memberID = try container.decode(UUID.self, forKey: .memberID)
        household = try container.decode(HouseholdSnapshot.self, forKey: .household)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .token)
        try container.encode(memberID, forKey: .memberID)
        try container.encode(household, forKey: .household)
    }
}

public struct AccountState: Sendable, Codable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let configured: Bool
    public let account: Account?
    public let memberships: [AccountMembership]
    public let devices: [AccountDevice]
    public let session: AccountKitchenSession?
    public let deletionPending: Bool
    private let csrfToken: String?

    public var isSignedIn: Bool { account != nil }

    private enum CodingKeys: String, CodingKey {
        case configured, account, memberships, devices, csrfToken, session, deletionPending
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decode(Bool.self, forKey: .configured)
        account = try container.decode(Account?.self, forKey: .account)
        memberships = try container.decode([AccountMembership].self, forKey: .memberships)
        devices = try container.decode([AccountDevice].self, forKey: .devices)
        csrfToken = try container.decode(String?.self, forKey: .csrfToken)
        session = try container.decode(AccountKitchenSession?.self, forKey: .session)
        if container.contains(.deletionPending) {
            guard try container.decode(Bool.self, forKey: .deletionPending) else {
                throw AccountError.invalidResponse
            }
            deletionPending = true
        } else {
            deletionPending = false
        }
        guard account != nil else {
            guard csrfToken == nil, session == nil, devices.isEmpty, memberships.isEmpty, !deletionPending else {
                throw AccountError.invalidResponse
            }
            return
        }
        guard let csrfToken, csrfToken.utf16.count >= 32,
              devices.filter(\.current).count == 1,
              Set(devices.map(\.id)).count == devices.count,
              Set(memberships.map(\.householdID)).count == memberships.count else {
            throw AccountError.invalidResponse
        }
        if deletionPending && (session != nil || !memberships.isEmpty || devices.count != 1) {
            throw AccountError.invalidResponse
        }
        if let session {
            guard memberships.contains(where: {
                $0.householdID == session.household.id && $0.memberID == session.memberID
            }), session.household.memberIDs.contains(session.memberID) else {
                throw AccountError.invalidResponse
            }
        }
    }

    func replacingHousehold(_ household: HouseholdSnapshot) throws -> AccountState {
        guard isSignedIn, !deletionPending, let session,
              session.household.id == household.id, household.memberIDs.contains(session.memberID),
              memberships.contains(where: { $0.householdID == household.id && $0.memberID == session.memberID }) else {
            throw AccountError.invalidResponse
        }
        return AccountState(
            replacing: self, session: AccountKitchenSession(memberID: session.memberID, household: household)
        )
    }

    private init(replacing original: AccountState, session: AccountKitchenSession) {
        configured = original.configured
        account = original.account
        memberships = original.memberships
        devices = original.devices
        self.session = session
        deletionPending = original.deletionPending
        csrfToken = original.csrfToken
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configured, forKey: .configured)
        try container.encode(account, forKey: .account)
        try container.encode(memberships, forKey: .memberships)
        try container.encode(devices, forKey: .devices)
        try container.encode(csrfToken, forKey: .csrfToken)
        try container.encode(session, forKey: .session)
        if deletionPending { try container.encode(true, forKey: .deletionPending) }
    }

    public var description: String {
        "AccountState(isSignedIn: \(isSignedIn), deletionPending: \(deletionPending))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["isSignedIn": isSignedIn, "deletionPending": deletionPending])
    }
}

private extension KeyedDecodingContainer {
    func name(forKey key: Key) throws -> String {
        guard let name = AccountValidation.name(try decode(String.self, forKey: key)) else {
            throw AccountError.invalidResponse
        }
        return name
    }

    func timestamp(forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard AccountValidation.timestamp(value) else { throw AccountError.invalidResponse }
        return value
    }
}
