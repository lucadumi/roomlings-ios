import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Monthly bills", .timeLimit(.minutes(1)))
struct BillsTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let memberID = UUID(uuidString: Fixtures.memberID)!
    private let roommateID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let billID = UUID(uuidString: "11223344-1122-4333-8444-112233445566")!
    private let mutationID = UUID(uuidString: "ddeeffaa-ddee-4ffa-8dde-aabbccddeeff")!

    // A draft bill the tests can reuse.
    private var draft: BillDraft {
        try! BillDraft(
            name: "Internet", amount: 4_200,
            firstDueDate: "2026-10-05", participants: [memberID, roommateID], timeZone: "Europe/Bucharest"
        )
    }

    @Test
    func creatingABillSendsTheExpectedRequestAndValidatesTheReceipt() async throws {
        let (session, transport) = try await restore(initial: household(), response: addedHousehold())
        let result = try await session.createBill(
            draft, householdID: householdID, version: 17, mutationID: mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/bills")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": .string(mutationID.uuidString.lowercased()),
            "name": .string("Internet"), "amount": .integer(4_200),
            "firstDueDate": .string("2026-10-05"), "timeZone": .string("Europe/Bucharest"),
            "participants": .array([.string(memberID.uuidString.lowercased()), .string(roommateID.uuidString.lowercased())]),
        ]))
        let bills = try HouseholdBills(household: #require(result.session?.household))
        #expect(bills.bills.first?.revisions.first?.name == "Internet")
        #expect(bills.bills.first?.startMonth == "2026-10")
    }

    @Test
    func aConflictRetainsTheOriginalVersionsAndIsNotRetriedAutomatically() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: household())),
            try Fixtures.failure(status: 409, code: nil),
        ])
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.server(status: 409, code: nil)) {
            try await session.createBill(draft, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func payingABillRecordsAnExpenseAndLeavesTheBillUnchanged() async throws {
        let (session, _) = try await restore(initial: billedHousehold(paid: false), response: billedHousehold(paid: true))
        let draft = try BillPaymentDraft(
            month: "2026-10", amount: 4_200, paidBy: memberID,
            participants: [memberID, roommateID], date: "2026-10-05"
        )
        let result = try await session.recordBillPayment(
            id: billID, draft: draft, householdID: householdID, version: 17, mutationID: mutationID
        )
        let bills = try HouseholdBills(household: #require(result.session?.household))
        let paid = try #require(bills.bills.first)
        let occurrence = try #require(bills.occurrence(of: paid, in: "2026-10"))
        #expect(occurrence.payment?.amount == 4_200)
        #expect(occurrence.payment?.bill?.billId == billID)
        #expect(occurrence.payment?.bill?.month == "2026-10")
    }

    @Test
    func pausingABillHidesItsOccurrenceForTheCurrentMonth() async throws {
        let paused = billedHousehold(paid: false, paused: true)
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(paused))
        let bill = try #require(bills.bills.first)
        #expect(bill.isPaused)
        #expect(bills.occurrence(of: bill, in: "2026-10") == nil)
    }

    @Test
    func shortMonthsClampTheDueDateToTheLastDay() throws {
        let rent: JSONValue = .object([
            "id": .string(billID.uuidString.lowercased()),
            "createdAt": .string("2026-01-01T00:00:00.000Z"),
            "startMonth": .string("2026-01"),
            "pauses": .array([]),
            "revisions": .array([.object([
                "fromMonth": .string("2026-01"),
                "name": .string("Rent"), "amount": .integer(100_000),
                "dueDay": .integer(31),
                "participants": .array([.string(memberID.uuidString.lowercased())]),
            ])]),
        ])
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(household(bills: [rent])))
        let bill = try #require(bills.bills.first)
        let occurrence = try #require(bills.occurrence(of: bill, in: "2026-02"))
        #expect(occurrence.dueDate == "2026-02-28")
    }

    // MARK: - Fixtures

    private func restore(initial: JSONValue, response: JSONValue) async throws -> (AccountSession, TestTransport) {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: initial)),
            try Fixtures.response(["household": response]),
        ])
        let session = make(transport)
        try await session.restore()
        return (session, transport)
    }

    private func make(_ transport: TestTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }

    private func household(bills: [JSONValue] = [], expenses: [JSONValue] = [], version: Int64 = 17) -> JSONValue {
        let base = ShoppingFixtures.household(version: version)
        return ShoppingFixtures.replacing(base, with: [
            "bills": .array(bills),
            "expenses": .array(expenses + (base["expenses"]?.arrayValue ?? [])),
        ])
    }

    private func bill(paused: Bool = false, startMonth: String = "2026-09") -> JSONValue {
        .object([
            "id": .string(billID.uuidString.lowercased()),
            "createdAt": .string("\(startMonth)-01T00:00:00.000Z"),
            "startMonth": .string(startMonth),
            "pauses": .array(paused ? [.object(["fromMonth": .string("2026-10"), "untilMonth": .null])] : []),
            "revisions": .array([.object([
                "fromMonth": .string(startMonth),
                "name": .string("Internet"), "amount": .integer(4_200),
                "dueDay": .integer(5),
                "participants": .array([.string(memberID.uuidString.lowercased()), .string(roommateID.uuidString.lowercased())]),
            ])]),
        ])
    }

    private func billedHousehold(paid: Bool, paused: Bool = false) -> JSONValue {
        let payment: JSONValue = .object([
            "id": .string("99999999-9999-4999-8999-999999999999"),
            "description": .string("Internet"),
            "amount": .integer(4_200),
            "paidBy": .string(memberID.uuidString.lowercased()),
            "participants": .array([.string(memberID.uuidString.lowercased()), .string(roommateID.uuidString.lowercased())]),
            "category": .string("other"), "date": .string("2026-10-05"),
            "createdAt": .string("2026-10-05T12:00:00.000Z"),
            "bill": .object([
                "billId": .string(billID.uuidString.lowercased()),
                "month": .string("2026-10"),
                "dueDate": .string("2026-10-05"),
            ]),
        ])
        let value = household(bills: [bill(paused: paused)], expenses: paid ? [payment] : [], version: paid ? 18 : 17)
        return paid ? ShoppingFixtures.withReceipt(value) : value
    }

    private func addedHousehold() -> JSONValue {
        ShoppingFixtures.withReceipt(household(bills: [bill(startMonth: "2026-10")], version: 18))
    }
}
