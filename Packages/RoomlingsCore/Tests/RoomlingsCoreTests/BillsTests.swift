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
        let occurrence = try #require(bills.occurrence(of: paid, in: "2026-10", today: "2026-10-16"))
        #expect(occurrence.status == .paid)
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
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-01") == nil)
    }

    @Test
    func undoingABillPaymentRemovesOnlyItsExpenseRecord() async throws {
        let (session, transport) = try await restore(
            initial: billedHousehold(paid: true, version: 17, receipt: false),
            response: ShoppingFixtures.withReceipt(billedHousehold(paid: false, version: 18))
        )
        let initial = try HouseholdLedger(household: #require(await session.state?.session?.household))
        let payment = try #require(initial.expenses.first { $0.isBillPayment })
        #expect(initial.canUndoBillPayment(payment, memberID: memberID))
        #expect(!initial.canRemove(payment, memberID: memberID))

        let result = try await session.removeBillPayment(
            id: payment.id, householdID: householdID, version: 17, mutationID: mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/expenses/\(payment.id.uuidString.lowercased())")
        let bills = try HouseholdBills(household: #require(result.session?.household))
        let bill = try #require(bills.bills.first)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-16")?.status == .overdue)
    }

    @Test
    func theReceiptRemovalPathStillRejectsABillPayment() async throws {
        let (session, _) = try await restore(
            initial: billedHousehold(paid: true, version: 17, receipt: false),
            response: ShoppingFixtures.withReceipt(billedHousehold(paid: false, version: 18))
        )
        let household = try #require(await session.state?.session?.household)
        let payment = try #require(HouseholdLedger(household: household).expenses.first { $0.isBillPayment })
        await #expect(throws: AccountError.invalidResponse) {
            try await session.removeExpense(id: payment.id, householdID: householdID, version: 17, mutationID: mutationID)
        }
    }

    @Test
    func unpaidStatusesFollowTheHouseholdBillingDate() throws {
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(billedHousehold(paid: false)))
        let bill = try #require(bills.bills.first)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-01")?.status == .upcoming)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-05")?.status == .due)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-06")?.status == .overdue)
    }

    @Test
    func pausingFromNextMonthKeepsThisMonthDue() throws {
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(household(bills: [
            bill(pauses: [.object(["fromMonth": .string("2026-11"), "untilMonth": .null])]),
        ])))
        let bill = try #require(bills.bills.first)
        #expect(bill.isPaused)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-16")?.status == .overdue)
        #expect(bills.occurrence(of: bill, in: "2026-11", today: "2026-10-16") == nil)
        #expect(bill.pauseMonth(current: "2026-10") == "2026-11")
    }

    @Test
    func aResumedBillIsScheduledAgainInItsResumeMonth() throws {
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(household(bills: [
            bill(pauses: [.object(["fromMonth": .string("2026-10"), "untilMonth": .string("2026-12")])]),
        ])))
        let bill = try #require(bills.bills.first)
        #expect(!bill.isPaused)
        #expect(bills.occurrence(of: bill, in: "2026-10", today: "2026-12-01") == nil)
        #expect(bills.occurrence(of: bill, in: "2026-11", today: "2026-12-01") == nil)
        #expect(bills.occurrence(of: bill, in: "2026-12", today: "2026-12-01")?.status == .upcoming)
    }

    @Test
    func aPaidMonthShowsTheRecordedExpenseEvenAfterAPause() throws {
        let paused = ShoppingFixtures.replacing(billedHousehold(paid: true), with: [
            "bills": .array([bill(pauses: [.object(["fromMonth": .string("2026-10"), "untilMonth": .null])])]),
        ])
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(paused))
        let bill = try #require(bills.bills.first)
        let occurrence = try #require(bills.occurrence(of: bill, in: "2026-10", today: "2026-10-16"))
        #expect(occurrence.status == .paid)
        #expect(occurrence.dueDate == "2026-10-05")
        #expect(occurrence.amount == 4_200)
    }

    @Test
    func earlierOverdueMonthsStayVisibleFromLaterMonths() throws {
        let bills = try HouseholdBills(household: ShoppingFixtures.snapshot(billedHousehold(paid: true)))
        // September is unpaid and past due; October is paid.
        let earlier = bills.earlierOverdue(before: "2026-11", today: "2026-11-02")
        #expect(earlier.count == 1)
        #expect(earlier.firstMonth == "2026-09")
        #expect(bills.earlierOverdue(before: "2026-09", today: "2026-11-02").count == 0)
        #expect(bills.firstMonth(current: "2026-11") == "2026-09")
        #expect(bills.monthlyBills(in: "2026-09", today: "2026-11-02").map(\.status) == [.overdue])
    }

    @Test
    func monthArithmeticCrossesYearsAndRejectsInvalidMonths() {
        #expect(HouseholdBills.addMonths("2026-12", 1) == "2027-01")
        #expect(HouseholdBills.addMonths("2026-01", -1) == "2025-12")
        #expect(HouseholdBills.addMonths("9999-12", 1) == nil)
        #expect(HouseholdBills.addMonths("2026-13", 1) == nil)
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
        let occurrence = try #require(bills.occurrence(of: bill, in: "2026-02", today: "2026-02-01"))
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

    private func bill(paused: Bool = false, startMonth: String = "2026-09", pauses: [JSONValue]? = nil) -> JSONValue {
        .object([
            "id": .string(billID.uuidString.lowercased()),
            "createdAt": .string("\(startMonth)-01T00:00:00.000Z"),
            "startMonth": .string(startMonth),
            "pauses": .array(pauses ?? (paused ? [.object(["fromMonth": .string("2026-10"), "untilMonth": .null])] : [])),
            "revisions": .array([.object([
                "fromMonth": .string(startMonth),
                "name": .string("Internet"), "amount": .integer(4_200),
                "dueDay": .integer(5),
                "participants": .array([.string(memberID.uuidString.lowercased()), .string(roommateID.uuidString.lowercased())]),
            ])]),
        ])
    }

    private func billedHousehold(paid: Bool, paused: Bool = false, version: Int64? = nil, receipt: Bool = true) -> JSONValue {
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
        let value = household(bills: [bill(paused: paused)], expenses: paid ? [payment] : [],
                              version: version ?? (paid ? 18 : 17))
        return paid && receipt ? ShoppingFixtures.withReceipt(value) : value
    }

    private func addedHousehold() -> JSONValue {
        ShoppingFixtures.withReceipt(household(bills: [bill(startMonth: "2026-10")], version: 18))
    }
}
