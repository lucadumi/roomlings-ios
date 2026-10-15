import Foundation

/// Room roles live outside the shared household document, so a role change must leave
/// every household field untouched apart from the version and its receipt.
struct HouseholdRoster: Sendable, Equatable {
    let householdVersion: Int64
    let members: [HouseholdMember]
    let preserved: JSONValue

    var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        guard case .object(var object) = household.value else { throw AccountError.invalidResponse }
        for key in ["version", "mutationReceipts"] { object[key] = nil }
        preserved = .object(object)
    }
}

extension HouseholdRoster: HouseholdProjection {
    static let collectionKey = "members"
}

typealias RosterMutationResponse = HouseholdMutationResponse<HouseholdRoster>

extension AccountAPI {
    func setRoomRole(
        memberID target: UUID, role: AccountRole, version: Int64, mutationID: UUID, memberID: UUID,
        roster: HouseholdRoster, token: SessionToken
    ) async throws -> RosterMutationResponse {
        guard role != .owner, roster.activeMembers.contains(where: { $0.id == target }) else {
            throw AccountError.invalidInput(.memberID)
        }
        let response: RosterMutationResponse = try await client.mutation(
            .setRoomRole(target), fields: ["role": .string(role.rawValue)], version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == roster.householdVersion, response.projection.preserved == roster.preserved else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}
