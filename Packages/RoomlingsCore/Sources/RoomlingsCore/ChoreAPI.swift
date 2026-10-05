import Foundation

extension AccountAPI {
    func updateChore(
        _ change: ChoreUpdate, version: Int64, mutationID: UUID, memberID: UUID,
        chores: HouseholdChores, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        let response: ChoreMutationResponse = try await client.mutation(
            change.endpoint, fields: change.requestFields(), version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == chores.householdVersion, change.matches(response.projection, from: chores) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}

enum ChoreUpdate: Sendable {
    case edit(UUID, ChoreDraft, Int64)
    case archive(UUID, Bool, Int64)

    var endpoint: APIEndpoint {
        switch self {
        case .edit(let id, _, _): .editChore(id)
        case .archive(let id, _, _): .setChoreArchived(id)
        }
    }

    private var target: (id: UUID, version: Int64) {
        switch self {
        case .edit(let id, _, let version), .archive(let id, _, let version): (id, version)
        }
    }

    func requestFields() throws -> [String: JSONValue] {
        guard (0..<ChoreValidation.maximumInteger).contains(target.version) else {
            throw AccountError.invalidInput(.choreVersion)
        }
        var fields: [String: JSONValue]
        switch self {
        case .edit(_, let draft, _): fields = draft.requestFields
        case .archive(_, let archived, _): fields = ["archived": .bool(archived)]
        }
        fields["choreVersion"] = .integer(target.version)
        return fields
    }

    func matches(_ result: HouseholdChores, from original: HouseholdChores) -> Bool {
        guard let previous = original.items.first(where: { $0.id == target.id }),
              previous.version == target.version,
              let updated = result.items.first(where: { $0.id == target.id }),
              updated.version == previous.version + 1,
              updated.createdAt == previous.createdAt, updated.createdBy == previous.createdBy,
              updated.occurrence == previous.occurrence,
              result.items.map(\.id) == original.items.map(\.id),
              result.items.filter({ $0.id != target.id }) == original.items.filter({ $0.id != target.id }),
              result.history == original.history, result.members == original.members,
              result.billingTimeZone == original.billingTimeZone else { return false }
        switch self {
        case .edit(_, let draft, _):
            return !previous.archived && !updated.archived
                && updated.title == draft.title && updated.notes == draft.notes
                && updated.roomID == draft.roomID && updated.area == draft.area
                && updated.componentID == draft.componentID
                && (draft.componentID == nil ? updated.componentName == nil : updated.componentName != nil)
                && updated.dueDate == draft.dueDate && updated.repeatDays == draft.repeatDays
                && updated.rotation == draft.rotation && updated.turn == draft.turn
                && draft.rotation.allSatisfy { id in original.activeMembers.contains { $0.id == id } }
        case .archive(_, let archived, _):
            return previous.archived != archived && updated.archived == archived
                && (archived || original.canRestore(previous))
                && updated.title == previous.title && updated.notes == previous.notes
                && updated.roomID == previous.roomID && updated.area == previous.area
                && updated.componentID == previous.componentID && updated.componentName == previous.componentName
                && updated.dueDate == previous.dueDate && updated.repeatDays == previous.repeatDays
                && updated.rotation == previous.rotation && updated.turn == previous.turn
        }
    }
}
