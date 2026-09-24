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

    func removeMember(
        id: UUID, householdID: UUID, version: Int64, token: SessionToken
    ) async throws -> HouseholdInvitationAccess {
        try validate(version: version)
        let access: HouseholdInvitationAccess = try await client.request(
            .removeHouseholdMember(householdID, id), body: JSONEncoder().encode(["version": version]), token: token
        )
        guard access.household.version == version + 1, access.role == .owner,
              access.members.contains(where: { $0.id == id && !$0.active }),
              try HouseholdMember.projection(access.household.value).contains(where: { $0.id == id && $0.inactive }) else {
            throw AccountError.invalidResponse
        }
        return access
    }

    func leave(householdID: UUID, version: Int64, token: SessionToken) async throws -> AccountState {
        try validate(version: version)
        let result: OrdinaryAccountResponse = try await client.request(
            .leaveHousehold(householdID), body: JSONEncoder().encode(["version": version]), token: token
        )
        guard result.state.isSignedIn, !result.state.deletionPending, result.state.session == nil,
              !result.state.memberships.contains(where: { $0.householdID == householdID }) else {
            throw AccountError.invalidResponse
        }
        return result.state
    }

    private func validate(version: Int64) throws {
        guard (0..<HouseholdValidation.maximumInteger).contains(version) else {
            throw AccountError.invalidInput(.version)
        }
    }
}
