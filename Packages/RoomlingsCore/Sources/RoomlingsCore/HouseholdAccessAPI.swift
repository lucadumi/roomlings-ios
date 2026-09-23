import Foundation

struct HouseholdAccessAPI: Sendable {
    let client: NativeAPIClient

    func load(householdID: UUID, token: SessionToken) async throws -> HouseholdInvitationAccess {
        try await client.request(.householdInvitations(householdID), token: token)
    }

    func create(householdID: UUID, version: Int64, token: SessionToken) async throws -> CreatedHouseholdInvitation {
        try validate(version: version)
        let result: CreatedHouseholdInvitation = try await client.request(
            .createInvitation(householdID),
            body: JSONEncoder().encode(["version": version, "expiresInDays": 7]), token: token
        )
        guard result.access.household.version == version + 1 else { throw AccountError.invalidResponse }
        return result
    }

    func revoke(id: UUID, householdID: UUID, version: Int64, token: SessionToken) async throws -> HouseholdInvitationAccess {
        try validate(version: version)
        let access: HouseholdInvitationAccess = try await client.request(
            .revokeInvitation(householdID, id),
            body: JSONEncoder().encode(["version": version]), token: token
        )
        guard access.role == .owner,
              access.household.version == version || access.household.version == version + 1,
              access.invitations.contains(where: { $0.id == id && $0.revokedAt != nil }) else {
            throw AccountError.invalidResponse
        }
        return access
    }

    func transferOwnership(
        to memberID: UUID, householdID: UUID, version: Int64, token: SessionToken
    ) async throws -> HouseholdInvitationAccess {
        try validate(version: version)
        let body: [String: JSONValue] = ["memberId": .string(memberID.uuidString.lowercased()), "version": .integer(version)]
        let access: HouseholdInvitationAccess = try await client.request(
            .transferOwnership(householdID), body: JSONEncoder().encode(body), token: token
        )
        guard access.household.version == version + 1, access.role == .member,
              access.members.contains(where: { $0.id == memberID && $0.role == .owner && $0.active && $0.linked }) else {
            throw AccountError.invalidResponse
        }
        return access
    }

    private func validate(version: Int64) throws {
        guard (0..<HouseholdValidation.maximumInteger).contains(version) else {
            throw AccountError.invalidInput(.version)
        }
    }
}
