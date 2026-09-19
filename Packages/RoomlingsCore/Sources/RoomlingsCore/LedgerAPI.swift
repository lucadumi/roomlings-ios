import Foundation

public struct ShoppingSelection: Sendable, Equatable {
    public let id: UUID
    public let version: Int64

    public init(id: UUID, version: Int64) {
        self.id = id
        self.version = version
    }

    public init(_ item: ShoppingItem) {
        id = item.id
        version = item.version
    }
}

struct LedgerAPI: Sendable {
    let client: NativeAPIClient

    func mutate(
        _ change: LedgerChange, version: Int64, mutationID: UUID, memberID: UUID,
        ledger: HouseholdLedger, token: SessionToken
    ) async throws -> LedgerMutationResponse {
        let response: LedgerMutationResponse = try await client.mutation(
            change.endpoint, fields: change.requestFields(), version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        // A receipt replay returns the latest household, even after another roommate's change.
        if !response.replayed {
            guard version == ledger.householdVersion,
                  change.matches(response.projection, from: ledger, memberID: memberID) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}

enum LedgerChange: Sendable {
    case record(ExpenseDraft)
    case checkout(ExpenseDraft, UUID, [ShoppingSelection])
    case remove(UUID)

    var endpoint: APIEndpoint {
        switch self {
        case .record: .recordExpense
        case .checkout: .checkoutShopping
        case .remove(let id): .removeExpense(id)
        }
    }

    func requestFields() throws -> [String: JSONValue] {
        switch self {
        case .record(let draft):
            return draft.requestFields
        case .checkout(let draft, let checkoutID, let selection):
            guard HouseholdValidation.uuid(checkoutID) else { throw AccountError.invalidInput(.checkoutID) }
            guard (1...HouseholdShopping.itemLimit).contains(selection.count),
                  Set(selection.map(\.id)).count == selection.count,
                  selection.allSatisfy({ HouseholdValidation.uuid($0.id) }) else {
                throw AccountError.invalidInput(.participants)
            }
            guard selection.allSatisfy({ (0..<HouseholdValidation.maximumInteger).contains($0.version) }) else {
                throw AccountError.invalidInput(.itemVersion)
            }
            var fields = draft.requestFields
            fields["checkoutId"] = .string(checkoutID.uuidString.lowercased())
            fields["items"] = .array(selection.map {
                .object(["id": .string($0.id.uuidString.lowercased()), "version": .integer($0.version)])
            })
            return fields
        case .remove:
            return [:]
        }
    }

    func matches(_ result: HouseholdLedger, from original: HouseholdLedger, memberID: UUID) -> Bool {
        switch self {
        case .record(let draft):
            guard result.runIDs == original.runIDs,
                  result.shoppingItemIDs == original.shoppingItemIDs else { return false }
            return recorded(result, from: original, draft: draft, runID: nil)
        case .checkout(let draft, let checkoutID, let selection):
            let removed = Set(selection.map(\.id))
            guard result.runIDs == original.runIDs.union([checkoutID]),
                  !original.runIDs.contains(checkoutID),
                  removed.isSubset(of: Set(original.shoppingItemIDs)),
                  result.shoppingItemIDs == original.shoppingItemIDs.filter({ !removed.contains($0) }) else {
                return false
            }
            return recorded(result, from: original, draft: draft, runID: checkoutID)
        case .remove(let id):
            guard let previous = original.expenses.first(where: { $0.id == id }),
                  original.canRemove(previous, memberID: memberID),
                  result.runIDs == original.runIDs,
                  result.shoppingItemIDs == original.shoppingItemIDs else { return false }
            return result.expenses == original.expenses.filter { $0.id != id }
        }
    }

    /// The server unshifts a new expense, so it is always the first entry and nothing else moves.
    private func recorded(
        _ result: HouseholdLedger, from original: HouseholdLedger, draft: ExpenseDraft, runID: UUID?
    ) -> Bool {
        guard result.expenses.count == original.expenses.count + 1,
              Array(result.expenses.dropFirst()) == original.expenses,
              let saved = result.expenses.first else { return false }
        return saved.description == draft.description && saved.amount == draft.amount
            && saved.paidBy == draft.paidBy && saved.participants == draft.participants
            && saved.category == draft.category && saved.date == draft.date
            && saved.shoppingRunID == runID && !saved.isBillPayment
    }
}
