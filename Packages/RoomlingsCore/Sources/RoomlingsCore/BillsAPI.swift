import Foundation

typealias BillsMutationResponse = HouseholdMutationResponse<HouseholdBills>

struct BillsAPI: Sendable {
    let client: NativeAPIClient

    func mutate(
        _ change: BillChange, version: Int64, mutationID: UUID, memberID: UUID,
        bills: HouseholdBills, token: SessionToken
    ) async throws -> BillsMutationResponse {
        let response: BillsMutationResponse = try await client.mutation(
            change.endpoint, fields: change.requestFields(), version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == bills.householdVersion,
                  change.matches(response.projection, from: bills, memberID: memberID) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}

enum BillChange: Sendable {
    case create(BillDraft)
    case edit(UUID, BillEditDraft)
    case pause(UUID, Bool)
    case pay(UUID, BillPaymentDraft)

    var endpoint: APIEndpoint {
        switch self {
        case .create: .addBill
        case .edit(let id, _): .editBill(id)
        case .pause(let id, _): .pauseBill(id)
        case .pay(let id, _): .payBill(id)
        }
    }

    func requestFields() -> [String: JSONValue] {
        switch self {
        case .create(let draft): draft.requestFields
        case .edit(_, let draft): draft.requestFields
        case .pause(_, let paused): ["paused": .bool(paused)]
        case .pay(_, let draft): draft.requestFields
        }
    }

    func matches(_ result: HouseholdBills, from original: HouseholdBills, memberID: UUID) -> Bool {
        switch self {
        case .create(let draft): matchesCreate(result, from: original, draft: draft)
        case .edit(let id, let draft): matchesEdit(result, from: original, id: id, draft: draft)
        case .pause(let id, let paused): matchesPause(result, from: original, id: id, paused: paused)
        case .pay(let id, let draft): matchesPay(result, from: original, id: id, draft: draft, memberID: memberID)
        }
    }

    /// The server unshifts the new bill. Nothing else moves.
    private func matchesCreate(_ result: HouseholdBills, from original: HouseholdBills, draft: BillDraft) -> Bool {
        guard result.bills.count == original.bills.count + 1,
              let created = result.bills.first,
              Array(result.bills.dropFirst()) == original.bills,
              created.revisions.count == 1,
              created.pauses.isEmpty,
              created.startMonth == String(draft.firstDueDate.prefix(7)),
              created.revisions[0].fromMonth == created.startMonth,
              created.revisions[0].name == draft.name,
              created.revisions[0].amount == draft.amount,
              created.revisions[0].dueDay == Int(draft.firstDueDate.suffix(2)),
              created.revisions[0].participants == draft.participants,
              result.expenses == original.expenses else { return false }
        return true
    }

    /// `reviseBill` leaves earlier months and other bills untouched and only changes the
    /// bill's revisions from the chosen month forward.
    private func matchesEdit(
        _ result: HouseholdBills, from original: HouseholdBills, id: UUID, draft: BillEditDraft
    ) -> Bool {
        guard let before = original.bills.first(where: { $0.id == id }),
              let after = result.bills.first(where: { $0.id == id }),
              before.createdAt == after.createdAt,
              before.startMonth == after.startMonth,
              after.pauses == before.pauses,
              result.bills.filter({ $0.id != id }) == original.bills.filter({ $0.id != id }),
              result.expenses == original.expenses else { return false }
        // Earlier revisions are preserved. A new revision is appended at the chosen month,
        // or a later revision is replaced from that month forward.
        let target = draft.fromMonth ?? before.revisions.last?.fromMonth ?? before.startMonth
        guard let applicable = after.revision(for: target),
              applicable.name == draft.name,
              applicable.amount == draft.amount,
              applicable.dueDay == draft.dueDay,
              applicable.participants == draft.participants else { return false }
        // Every month before the target resolves to its old revision.
        for revision in before.revisions where revision.fromMonth < target {
            guard after.revision(for: revision.fromMonth) == revision else { return false }
        }
        return true
    }

    /// `setBillPaused` appends or closes a pause. Every other bill and every expense is unchanged.
    private func matchesPause(
        _ result: HouseholdBills, from original: HouseholdBills, id: UUID, paused: Bool
    ) -> Bool {
        guard let after = result.bills.first(where: { $0.id == id }),
              result.bills.filter({ $0.id != id }) == original.bills.filter({ $0.id != id }),
              result.expenses == original.expenses else { return false }
        return after.isPaused == paused
    }

    /// A bill payment is a money mutation. It records a new expense at the front of the
    /// ledger and leaves the bill itself untouched.
    private func matchesPay(
        _ result: HouseholdBills, from original: HouseholdBills, id: UUID, draft: BillPaymentDraft, memberID: UUID
    ) -> Bool {
        guard result.bills == original.bills,
              result.expenses.count == original.expenses.count + 1,
              Array(result.expenses.dropFirst()) == original.expenses,
              let saved = result.expenses.first,
              saved.bill?.billId == id,
              saved.bill?.month == draft.month,
              saved.description == (result.bills.first(where: { $0.id == id })?.revision(for: draft.month)?.name),
              saved.amount == draft.amount,
              saved.paidBy == draft.paidBy,
              saved.participants == draft.participants,
              saved.date == draft.date else { return false }
        _ = memberID
        return true
    }
}
