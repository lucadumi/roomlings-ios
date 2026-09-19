import Foundation
import Testing
@testable import RoomlingsCore

/// Balances and repayments must agree with the shared web algorithm exactly, so these build
/// small ledgers with known member IDs rather than reusing the shopping fixture.
@Suite("Ledger balances", .timeLimit(.minutes(1)))
struct LedgerBalanceTests {
    private func member(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "%08d-0000-4000-8000-000000000000", index))!
    }

    private func ledger(
        members count: Int,
        expenses: [(amount: Int64, paidBy: Int, participants: [Int])] = [],
        settlements: [(from: Int, to: Int, amount: Int64)] = []
    ) throws -> HouseholdLedger {
        let people = (0..<count).map(member)
        let memberValues = people.map { id in
            JSONValue.object([
                "id": .string(id.uuidString.lowercased()), "name": .string("Member \(id.uuidString.prefix(8))"),
                "color": .string("#7d9070"),
            ])
        }
        let expenseValues = expenses.enumerated().map { index, expense in
            JSONValue.object([
                "id": .string(String(format: "%08d-1111-4111-8111-111111111111", index)),
                "description": .string("Expense \(index)"), "amount": .integer(expense.amount),
                "paidBy": .string(people[expense.paidBy].uuidString.lowercased()),
                "participants": .array(expense.participants.map { .string(people[$0].uuidString.lowercased()) }),
                "category": .string("other"), "date": .string("2026-09-18"),
                "createdAt": .string("2026-09-18T12:00:00Z"),
            ])
        }
        let settlementValues = settlements.enumerated().map { index, settlement in
            JSONValue.object([
                "id": .string(String(format: "%08d-2222-4222-8222-222222222222", index)),
                "from": .string(people[settlement.from].uuidString.lowercased()),
                "to": .string(people[settlement.to].uuidString.lowercased()),
                "amount": .integer(settlement.amount),
                "createdAt": .string("2026-09-18T13:00:00Z"),
            ])
        }
        let household = ShoppingFixtures.replacing(ShoppingFixtures.household(items: []), with: [
            "members": .array(memberValues), "expenses": .array(expenseValues),
            "settlements": .array(settlementValues),
            "shopping": .object(["items": .array([]), "runs": .array([])]),
        ])
        return try HouseholdLedger(household: ShoppingFixtures.snapshot(household))
    }

    private func amounts(_ ledger: HouseholdLedger) -> [Int64] {
        ledger.balances.map(\.amount)
    }

    @Test
    func aPaidExpenseCreditsThePayerAndDebitsEveryShare() throws {
        let board = try ledger(members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])])
        #expect(amounts(board) == [500, -500])
        #expect(amounts(board).reduce(0, +) == 0)
    }

    @Test
    func anOddAmountKeepsTheBalancesWholeAndSquare() throws {
        let board = try ledger(members: 3, expenses: [(amount: 1_001, paidBy: 0, participants: [0, 1, 2])])
        // 1001 splits into 334, 334 and 333 by sorted member ID, so the payer keeps the rest.
        #expect(amounts(board) == [1_001 - 334, -334, -333])
        #expect(amounts(board).reduce(0, +) == 0)
    }

    @Test
    func aRepaymentMovesTheBalanceBackTowardsZero() throws {
        let before = try ledger(members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])])
        #expect(amounts(before) == [500, -500])
        let after = try ledger(
            members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])],
            settlements: [(from: 1, to: 0, amount: 500)]
        )
        #expect(amounts(after) == [0, 0])
    }

    @Test
    func aPartialRepaymentLeavesTheRemainder() throws {
        let board = try ledger(
            members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])],
            settlements: [(from: 1, to: 0, amount: 200)]
        )
        #expect(amounts(board) == [300, -300])
        #expect(amounts(board).reduce(0, +) == 0)
    }

    @Test
    func balancesAlwaysSumToZeroAcrossAMixedLedger() throws {
        let board = try ledger(
            members: 4,
            expenses: [
                (amount: 3_333, paidBy: 0, participants: [0, 1, 2]),
                (amount: 1_000, paidBy: 2, participants: [0, 1, 2, 3]),
                (amount: 77, paidBy: 3, participants: [1, 3]),
            ],
            settlements: [(from: 1, to: 0, amount: 100)]
        )
        #expect(amounts(board).reduce(0, +) == 0)
        #expect(board.balances.count == 4)
    }

    @Test
    func anInactiveRoommateKeepsTheirPosition() throws {
        let board = try ledger(members: 3, expenses: [(amount: 900, paidBy: 2, participants: [0, 1, 2])])
        #expect(amounts(board) == [-300, -300, 600])
    }

    @Test
    func suggestedRepaymentsSettleEveryoneExactly() throws {
        let board = try ledger(
            members: 4,
            expenses: [
                (amount: 3_333, paidBy: 0, participants: [0, 1, 2]),
                (amount: 1_000, paidBy: 2, participants: [0, 1, 2, 3]),
                (amount: 77, paidBy: 3, participants: [1, 3]),
            ]
        )
        let transfers = board.suggestedTransfers
        #expect(!transfers.isEmpty)
        #expect(transfers.allSatisfy { $0.amount > 0 && $0.from != $0.to })
        var totals = Dictionary(uniqueKeysWithValues: board.balances.map { ($0.member.id, $0.amount) })
        for transfer in transfers {
            totals[transfer.from, default: 0] += transfer.amount
            totals[transfer.to, default: 0] -= transfer.amount
        }
        #expect(totals.values.allSatisfy { $0 == 0 })
    }

    @Test
    func aSquareLedgerSuggestsNothing() throws {
        let board = try ledger(
            members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])],
            settlements: [(from: 1, to: 0, amount: 500)]
        )
        #expect(board.suggestedTransfers.isEmpty)
        #expect(board.balances.allSatisfy { $0.amount == 0 })
    }

    @Test
    func everySuggestedRepaymentIsOneTheServerWouldAccept() throws {
        let board = try ledger(
            members: 4,
            expenses: [
                (amount: 3_333, paidBy: 0, participants: [0, 1, 2]),
                (amount: 1_000, paidBy: 2, participants: [0, 1, 2, 3]),
            ]
        )
        for transfer in board.suggestedTransfers {
            #expect(board.canSettle(from: transfer.from, to: transfer.to, amount: transfer.amount))
        }
    }

    @Test
    func theGuardRailsRefuseRepaymentsTheLedgerCannotTake() throws {
        let board = try ledger(members: 2, expenses: [(amount: 1_000, paidBy: 0, participants: [0, 1])])
        let owed = member(0)
        let owing = member(1)
        #expect(board.canSettle(from: owing, to: owed, amount: 500))
        #expect(board.canSettle(from: owing, to: owed, amount: 1))
        // More than the debt, the wrong direction, a stranger, zero and self-payment all fail.
        #expect(!board.canSettle(from: owing, to: owed, amount: 501))
        #expect(!board.canSettle(from: owed, to: owing, amount: 500))
        #expect(!board.canSettle(from: owing, to: owing, amount: 500))
        #expect(!board.canSettle(from: owing, to: member(9), amount: 500))
        #expect(!board.canSettle(from: owing, to: owed, amount: 0))
        #expect(!board.canSettle(from: owing, to: owed, amount: -500))
    }
}

@Suite("Ledger repayments", .timeLimit(.minutes(1)))
struct LedgerSettlementTests {
    private func makeSession(_ transport: any HTTPTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
                       transport: transport)
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }

    @Test
    func recordingARepaymentSendsOnlyTheTransferAndSquaresTheBalances() async throws {
        let owing = LedgerFixtures.owingMember
        let owed = LedgerFixtures.owedMember
        let before = try LedgerFixtures.projection(LedgerFixtures.owingHousehold())
        let amount = try #require(before.suggestedTransfers.first?.amount)
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state(household: LedgerFixtures.owingHousehold())),
            try Fixtures.response(["household": LedgerFixtures.settled(amount: amount)], path: "api/settlements")
        ])
        let session = makeSession(transport)
        _ = try await session.restore()
        let updated = try await session.recordSettlement(
            from: owing, to: owed, amount: amount,
            householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/api/settlements")
        #expect(request.httpMethod == "POST")
        #expect(try body(request) == .object([
            "from": .string(owing.uuidString.lowercased()), "to": .string(owed.uuidString.lowercased()),
            "amount": .integer(amount), "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": LedgerFixtures.id(ShoppingFixtures.mutationID)
        ]))
        let after = try #require(updated.session.map { try HouseholdLedger(household: $0.household) })
        #expect(after.settlements.count == 1)
        #expect(after.balances.allSatisfy { $0.amount == 0 })
        #expect(after.suggestedTransfers.isEmpty)
    }

    @Test
    func undoingARepaymentPutsTheBalanceBack() async throws {
        let before = try LedgerFixtures.projection(LedgerFixtures.owingHousehold())
        let amount = try #require(before.suggestedTransfers.first?.amount)
        let settled = LedgerFixtures.settled(amount: amount)
        let path = "api/settlements/\(LedgerFixtures.settlementID.uuidString.lowercased())"
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state(household: settled)),
            try Fixtures.response(["household": LedgerFixtures.undone()], path: path)
        ])
        let session = makeSession(transport)
        let restored = try await session.restore()
        let squared = try #require(restored.session.map { try HouseholdLedger(household: $0.household) })
        #expect(squared.balances.allSatisfy { $0.amount == 0 })
        let updated = try await session.removeSettlement(
            id: LedgerFixtures.settlementID, householdID: ShoppingFixtures.householdID,
            version: 18, mutationID: ShoppingFixtures.undoMutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/\(path)")
        #expect(request.httpMethod == "DELETE")
        #expect(try body(request) == .object([
            "version": .integer(18), "mutationVersion": .integer(18),
            "mutationId": LedgerFixtures.id(ShoppingFixtures.undoMutationID)
        ]))
        let after = try #require(updated.session.map { try HouseholdLedger(household: $0.household) })
        #expect(after.settlements.isEmpty)
        #expect(after.balances == before.balances)
        #expect(after.suggestedTransfers == before.suggestedTransfers)
    }

    @Test
    func aRepaymentTheBalancesDoNotAllowIsRejectedEvenIfTheServerEchoesIt() async throws {
        let before = try LedgerFixtures.projection(LedgerFixtures.owingHousehold())
        let amount = try #require(before.suggestedTransfers.first?.amount)
        // Paying the wrong way round would make both balances worse, so the echo is refused.
        let backwards = ShoppingFixtures.replacing(LedgerFixtures.settled(amount: amount), with: [
            "settlements": .array([.object([
                "id": LedgerFixtures.id(LedgerFixtures.settlementID),
                "from": LedgerFixtures.id(LedgerFixtures.owedMember),
                "to": LedgerFixtures.id(LedgerFixtures.owingMember),
                "amount": .integer(amount), "createdAt": .string(LedgerFixtures.createdAt)
            ])])
        ])
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state(household: LedgerFixtures.owingHousehold())),
            try Fixtures.response(["household": backwards], path: "api/settlements")
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.recordSettlement(
                from: LedgerFixtures.owedMember, to: LedgerFixtures.owingMember, amount: amount,
                householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
    }

    @Test
    func aServerLedgerThatDoesNotMatchTheRepaymentIsRejected() async throws {
        let owing = LedgerFixtures.owingMember
        let owed = LedgerFixtures.owedMember
        let before = try LedgerFixtures.projection(LedgerFixtures.owingHousehold())
        let amount = try #require(before.suggestedTransfers.first?.amount)
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state(household: LedgerFixtures.owingHousehold())),
            try Fixtures.response(["household": LedgerFixtures.settled(amount: amount - 1)], path: "api/settlements")
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.recordSettlement(
                from: owing, to: owed, amount: amount,
                householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
    }

    @Test
    func aStaleRepaymentKeepsTheLocalBalancesUntouched() async throws {
        let owing = LedgerFixtures.owingMember
        let owed = LedgerFixtures.owedMember
        let before = try LedgerFixtures.projection(LedgerFixtures.owingHousehold())
        let amount = try #require(before.suggestedTransfers.first?.amount)
        let transport = TestTransport(responses: [
            try Fixtures.response(LedgerFixtures.state(household: LedgerFixtures.owingHousehold())),
            try Fixtures.response(
                ["error": .string("These balances have changed. Use the updated repayment suggestion.")],
                status: 409, path: "api/settlements"
            )
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.server(status: 409, code: nil)) {
            try await session.recordSettlement(
                from: owing, to: owed, amount: amount,
                householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
    }
}
