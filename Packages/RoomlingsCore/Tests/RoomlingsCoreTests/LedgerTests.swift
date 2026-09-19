import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Ledger cent arithmetic", .timeLimit(.minutes(1)))
struct LedgerMoneyTests {
    private func members(_ count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuidString: String(format: "%08d-0000-4000-8000-000000000000", index))!
        }
    }

    private func draft(_ amount: Int64, _ participants: [UUID]) throws -> ExpenseDraft {
        try ExpenseDraft(
            description: "Groceries", amount: amount, paidBy: participants[0],
            participants: participants, category: .other, date: "2026-09-18"
        )
    }

    @Test(arguments: [1, 2, 3, 5, 7, 12])
    func everyShareIsWholeCentsAndTheSplitLosesNothing(count: Int) throws {
        let participants = members(count)
        for amount in [Int64(1), 2, 99, 100, 101, 1_001, 2_599, 99_999_999, 100_000_000] {
            let shares = try draft(amount, participants).shares
            #expect(shares.count == count)
            #expect(shares.values.reduce(0, +) == amount)
            let base = amount / Int64(count)
            #expect(shares.values.allSatisfy { $0 == base || $0 == base + 1 })
        }
    }

    @Test
    func theRemainderFollowsTheSortedMemberOrderTheServerUses() throws {
        let participants = members(3)
        let sorted = participants.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let shares = try draft(1_001, participants.reversed()).shares
        #expect(shares[sorted[0]] == 334)
        #expect(shares[sorted[1]] == 334)
        #expect(shares[sorted[2]] == 333)
        #expect(shares.values.reduce(0, +) == 1_001)
    }

    @Test
    func aRecordedExpenseSplitsExactlyLikeItsDraft() throws {
        let ledger = try LedgerFixtures.projection(LedgerFixtures.recorded())
        let saved = try #require(ledger.expenses.first)
        #expect(saved.amount == 2_599)
        #expect(saved.shares == LedgerFixtures.draft.shares)
        #expect(saved.shares.values.reduce(0, +) == saved.amount)
    }

    @Test(arguments: [Int64(0), -1, -2_599, 100_000_001, Int64.max])
    func amountsOutsideWholePositiveCentsAreRejected(amount: Int64) {
        #expect(throws: AccountError.invalidInput(.amount)) { try draft(amount, members(2)) }
    }

    @Test
    func aDraftKeepsTheServersTextAndParticipantRules() throws {
        let participants = members(2)
        #expect(throws: AccountError.invalidInput(.expenseDescription)) {
            try ExpenseDraft(description: "   ", amount: 100, paidBy: participants[0],
                             participants: participants, category: .other, date: "2026-09-18")
        }
        #expect(throws: AccountError.invalidInput(.expenseDescription)) {
            try ExpenseDraft(description: String(repeating: "a", count: 101), amount: 100, paidBy: participants[0],
                             participants: participants, category: .other, date: "2026-09-18")
        }
        #expect(throws: AccountError.invalidInput(.participants)) {
            try ExpenseDraft(description: "Groceries", amount: 100, paidBy: participants[0],
                             participants: [], category: .other, date: "2026-09-18")
        }
        #expect(throws: AccountError.invalidInput(.participants)) {
            try ExpenseDraft(description: "Groceries", amount: 100, paidBy: participants[0],
                             participants: [participants[0], participants[0]], category: .other, date: "2026-09-18")
        }
        #expect(throws: AccountError.invalidInput(.participants)) {
            try ExpenseDraft(description: "Groceries", amount: 100, paidBy: participants[0],
                             participants: members(13), category: .other, date: "2026-09-18")
        }
        for date in ["2026-02-30", "2026-9-18", "18-09-2026", "", "2026-09-18T12:00:00Z"] {
            #expect(throws: AccountError.invalidInput(.date)) {
                try ExpenseDraft(description: "Groceries", amount: 100, paidBy: participants[0],
                                 participants: participants, category: .other, date: date)
            }
        }
        let trimmed = try ExpenseDraft(description: "  Weekly groceries  ", amount: 100, paidBy: participants[0],
                                       participants: participants, category: .produce, date: "2026-09-18")
        #expect(trimmed.description == "Weekly groceries")
    }

    @Test
    func requestFieldsMatchTheSharedExpenseSchema() {
        #expect(LedgerFixtures.draft.requestFields == LedgerFixtures.requestFields)
    }
}

@Suite("Ledger mutations", .timeLimit(.minutes(1)))
struct LedgerSessionTests {
    private func makeSession(_ transport: any HTTPTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
                       transport: transport)
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }

    private func selection() -> [ShoppingSelection] {
        [ShoppingSelection(id: ShoppingFixtures.itemID, version: 4)]
    }

    @Test
    func recordingAnExpensePostsTheSharedSchemaAndPublishesTheServerLedger() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": LedgerFixtures.recorded()], path: "api/expenses")
        ])
        let session = makeSession(transport)
        _ = try await session.restore()
        let updated = try await session.recordExpense(
            LedgerFixtures.draft, householdID: ShoppingFixtures.householdID,
            version: 17, mutationID: ShoppingFixtures.mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/api/expenses")
        #expect(request.httpMethod == "POST")
        let expected = LedgerFixtures.requestFields.merging([
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": LedgerFixtures.id(ShoppingFixtures.mutationID)
        ]) { _, new in new }
        #expect(try body(request) == .object(expected))
        for key in ["householdId", "memberId", "checkoutId", "items", "session", "accessToken"] {
            #expect(try body(request)[key] == nil)
        }
        let ledger = try #require(updated.session.map { try HouseholdLedger(household: $0.household) })
        #expect(ledger.expenses.first?.id == LedgerFixtures.recordedID)
        #expect(ledger.expenses.first?.amount == 2_599)
        #expect(ledger.expenses.first?.shoppingRunID == nil)
    }

    @Test
    func aBasketCheckoutSendsItemVersionsAndClearsExactlyThoseItems() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": LedgerFixtures.checkedOut()], path: "api/shopping/checkout")
        ])
        let session = makeSession(transport)
        _ = try await session.restore()
        let updated = try await session.checkoutShopping(
            LedgerFixtures.draft, checkoutID: LedgerFixtures.checkoutID, selection: selection(),
            householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/api/shopping/checkout")
        #expect(request.httpMethod == "POST")
        let sent = try body(request)
        #expect(sent["checkoutId"] == LedgerFixtures.id(LedgerFixtures.checkoutID))
        #expect(sent["items"] == .array([.object([
            "id": LedgerFixtures.id(ShoppingFixtures.itemID), "version": .integer(4)
        ])]))
        #expect(sent["amount"] == .integer(2_599))
        let shopping = try #require(updated.session.map { try HouseholdShopping(household: $0.household) })
        #expect(!shopping.items.contains { $0.id == ShoppingFixtures.itemID })
        let ledger = try #require(updated.session.map { try HouseholdLedger(household: $0.household) })
        #expect(ledger.expenses.first?.shoppingRunID == LedgerFixtures.checkoutID)
    }

    @Test
    func removingAReceiptSendsOnlyTheVersionEnvelope() async throws {
        let path = "api/expenses/\(LedgerFixtures.plainExpenseID.uuidString.lowercased())"
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": LedgerFixtures.removed()], path: path)
        ])
        let session = makeSession(transport)
        _ = try await session.restore()
        let updated = try await session.removeExpense(
            id: LedgerFixtures.plainExpenseID, householdID: ShoppingFixtures.householdID,
            version: 17, mutationID: ShoppingFixtures.mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/\(path)")
        #expect(request.httpMethod == "DELETE")
        #expect(try body(request) == .object([
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": LedgerFixtures.id(ShoppingFixtures.mutationID)
        ]))
        let ledger = try #require(updated.session.map { try HouseholdLedger(household: $0.household) })
        #expect(!ledger.expenses.contains { $0.id == LedgerFixtures.plainExpenseID })
    }

    @Test
    func aStaleVersionKeepsTheLocalLedgerUntouched() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(
                ["error": .string("Kitchen changed. Review the latest details and try again.")],
                status: 409, path: "api/expenses"
            )
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.server(status: 409, code: nil)) {
            try await session.recordExpense(
                LedgerFixtures.draft, householdID: ShoppingFixtures.householdID,
                version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
    }

    @Test
    func aServerLedgerThatDoesNotMatchTheDraftIsRejected() async throws {
        let wrongAmount = ShoppingFixtures.replacing(LedgerFixtures.saved(), with: ["amount": .integer(2_600)])
        let expenses = (LedgerFixtures.household()["expenses"]?.arrayValue ?? [])
        let household = ShoppingFixtures.withReceipt(
            LedgerFixtures.household(expenses: [wrongAmount] + expenses, version: 18)
        )
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": household], path: "api/expenses")
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.recordExpense(
                LedgerFixtures.draft, householdID: ShoppingFixtures.householdID,
                version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
    }

    @Test
    func aCheckoutThatLeavesTheBasketBehindIsRejected() async throws {
        // The receipt is recorded but the claimed item never left the shared list.
        let expenses = (LedgerFixtures.household()["expenses"]?.arrayValue ?? [])
        let household = ShoppingFixtures.withReceipt(LedgerFixtures.household(
            expenses: [LedgerFixtures.saved(runID: LedgerFixtures.checkoutID)] + expenses, version: 18
        ))
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": household], path: "api/shopping/checkout")
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.checkoutShopping(
                LedgerFixtures.draft, checkoutID: LedgerFixtures.checkoutID, selection: selection(),
                householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
    }

    @Test
    func aReplayedReceiptIsAcceptedEvenWhenAnotherRoommateChangedTheLedger() async throws {
        // A roommate recorded their own receipt first, so the replay no longer leads the ledger.
        let newer = ShoppingFixtures.replacing(LedgerFixtures.plainExpense, with: [
            "id": .string("15151515-1515-4151-8151-151515151515"), "description": .string("Late night shop")
        ])
        let expenses = (LedgerFixtures.household()["expenses"]?.arrayValue ?? [])
        let moved = ShoppingFixtures.withReceipt(LedgerFixtures.household(
            expenses: [newer, LedgerFixtures.saved()] + expenses, version: 19
        ))
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": moved, "replayed": .bool(true)], path: "api/expenses")
        ])
        let session = makeSession(transport)
        _ = try await session.restore()
        let updated = try await session.recordExpense(
            LedgerFixtures.draft, householdID: ShoppingFixtures.householdID,
            version: 17, mutationID: ShoppingFixtures.mutationID
        )
        #expect(updated.session?.household.version == 19)
    }

    @Test
    func aMissingMutationReceiptIsRejected() async throws {
        let expenses = (LedgerFixtures.household()["expenses"]?.arrayValue ?? [])
        let household = LedgerFixtures.household(expenses: [LedgerFixtures.saved()] + expenses, version: 18)
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state()),
            try Fixtures.response(["household": household], path: "api/expenses")
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.recordExpense(
                LedgerFixtures.draft, householdID: ShoppingFixtures.householdID,
                version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
    }
}

@Suite("Ledger projection", .timeLimit(.minutes(1)))
struct LedgerProjectionTests {
    @Test
    func theProjectionReadsEveryRecordedExpense() throws {
        let ledger = try LedgerFixtures.projection()
        #expect(ledger.expenses.count == 2)
        let plain = try #require(ledger.expenses.first { $0.id == LedgerFixtures.plainExpenseID })
        #expect(plain.amount == 450)
        #expect(plain.category == .pantry)
        #expect(plain.shoppingRunID == nil)
        #expect(plain.isBillPayment == false)
        let run = try #require(ledger.expenses.first { $0.id == LedgerFixtures.runExpenseID })
        #expect(run.shoppingRunID != nil)
        #expect(ledger.activeMembers.count == 2)
    }

    @Test
    func onlyPlainExpensesCanBeRemovedFromTheApp() throws {
        let ledger = try LedgerFixtures.projection()
        let plain = try #require(ledger.expenses.first { $0.id == LedgerFixtures.plainExpenseID })
        let run = try #require(ledger.expenses.first { $0.id == LedgerFixtures.runExpenseID })
        #expect(ledger.canRemove(plain, memberID: ShoppingFixtures.memberID))
        #expect(!ledger.canRemove(run, memberID: ShoppingFixtures.memberID))
        #expect(!ledger.canRemove(plain, memberID: ShoppingFixtures.inactiveID))
    }

    @Test(arguments: [
        ["amount": JSONValue.number(4.5)], ["amount": .integer(0)], ["amount": .integer(100_000_001)],
        ["category": .string("rent")], ["date": .string("2026-02-30")],
        ["participants": .array([])], ["description": .string("")]
    ])
    func anInvalidExpenseIsRefusedRatherThanShown(change: [String: JSONValue]) {
        let broken = ShoppingFixtures.replacing(LedgerFixtures.plainExpense, with: change)
        #expect(throws: (any Error).self) {
            try LedgerFixtures.projection(LedgerFixtures.household(expenses: [broken]))
        }
    }

    @Test
    func anExpenseNamingAnUnknownRoommateIsRefused() {
        let stranger = ShoppingFixtures.replacing(LedgerFixtures.plainExpense, with: [
            "participants": .array([.string("99999999-9999-4999-8999-999999999999")])
        ])
        #expect(throws: AccountError.invalidResponse) {
            try LedgerFixtures.projection(LedgerFixtures.household(expenses: [stranger]))
        }
    }
}
