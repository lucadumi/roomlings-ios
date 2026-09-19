import Foundation

struct ShoppingAPI: Sendable {
    let client: NativeAPIClient

    func mutate(
        _ change: ShoppingChange, version: Int64, mutationID: UUID, memberID: UUID,
        shopping: HouseholdShopping, token: SessionToken
    ) async throws -> ShoppingMutationResponse {
        let response: ShoppingMutationResponse = try await client.mutation(
            change.endpoint, fields: change.requestFields(), version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        // A receipt replay returns the latest household, even after another edit or deletion.
        if !response.replayed {
            guard version == shopping.householdVersion,
                  change.matches(response.projection, from: shopping, memberID: memberID) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}

enum ShoppingChange: Sendable {
    case add(ShoppingDraft)
    case edit(UUID, ShoppingDraft, Int64)
    case remove(UUID, Int64)
    case claim(UUID, Bool, Int64)
    case pick(UUID, Bool, Int64)

    var endpoint: APIEndpoint {
        switch self {
        case .add: .addShoppingItem
        case .edit(let id, _, _): .editShoppingItem(id)
        case .remove(let id, _): .removeShoppingItem(id)
        case .claim(let id, _, _): .claimShoppingItem(id)
        case .pick(let id, _, _): .pickShoppingItem(id)
        }
    }

    private var target: (id: UUID, version: Int64)? {
        switch self {
        case .add: nil
        case .edit(let id, _, let version), .remove(let id, let version),
             .claim(let id, _, let version), .pick(let id, _, let version): (id, version)
        }
    }

    func requestFields() throws -> [String: JSONValue] {
        var fields: [String: JSONValue]
        switch self {
        case .add(let draft), .edit(_, let draft, _): fields = draft.requestFields
        case .remove: fields = [:]
        case .claim(_, let claim, _): fields = ["claimed": .bool(claim)]
        case .pick(_, let pickedUp, _): fields = ["pickedUp": .bool(pickedUp)]
        }
        if let target {
            let maximum = HouseholdValidation.maximumInteger
            let canIncrement: Bool
            if case .remove = self { canIncrement = false } else { canIncrement = true }
            guard (0...(canIncrement ? maximum - 1 : maximum)).contains(target.version) else {
                throw AccountError.invalidInput(.itemVersion)
            }
            fields["itemVersion"] = .integer(target.version)
        }
        return fields
    }

    func matches(_ result: HouseholdShopping, from original: HouseholdShopping, memberID: UUID) -> Bool {
        if case .add(let draft) = self {
            guard result.items.count == original.items.count + 1,
                  Array(result.items.dropLast()) == original.items, let added = result.items.last else { return false }
            return added.name == draft.name && added.quantity == draft.quantity && added.notes == draft.notes
                && added.version == 0 && added.createdBy == memberID && added.claimedBy == nil && !added.pickedUp
                && added.createdAt == added.updatedAt && added.componentSources == nil
        }
        guard let target, let previous = original.items.first(where: { $0.id == target.id }),
              previous.version == target.version else { return false }
        let unchanged = original.items.filter { $0.id != target.id }
        if case .remove = self {
            return original.canEdit(previous, memberID: memberID) && result.items == unchanged
        }
        guard result.items.map(\.id) == original.items.map(\.id),
              result.items.filter({ $0.id != target.id }) == unchanged,
              let updated = result.items.first(where: { $0.id == target.id }),
              updated.version == previous.version + 1, updated.createdBy == previous.createdBy,
              updated.createdAt == previous.createdAt, updated.componentSources == previous.componentSources else {
            return false
        }
        if case .edit(_, let draft, _) = self {
            return original.canEdit(previous, memberID: memberID)
                && updated.name == draft.name && updated.quantity == draft.quantity && updated.notes == draft.notes
                && updated.claimedBy == previous.claimedBy && updated.pickedUp == previous.pickedUp
        }
        guard updated.name == previous.name, updated.quantity == previous.quantity,
              updated.notes == previous.notes else { return false }
        switch self {
        case .claim(_, let claim, _):
            return original.canClaim(previous, claim: claim, memberID: memberID)
                && updated.claimedBy == (claim ? memberID : nil) && !updated.pickedUp
        case .pick(_, let pickedUp, _):
            return original.canPick(previous, pickedUp: pickedUp, memberID: memberID)
                && updated.pickedUp == pickedUp && updated.claimedBy == (pickedUp ? memberID : previous.claimedBy)
        default:
            return false
        }
    }
}
