import Foundation
import Testing
@testable import RoomlingsCore

@Suite("House pot")
struct HousePotTests {
    private static func expense(_ id: String, amount: Int64, date: String, bill: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "description": .string("Groceries"), "amount": .integer(amount),
            "paidBy": LedgerFixtures.id(ShoppingFixtures.memberID),
            "participants": .array([LedgerFixtures.id(ShoppingFixtures.memberID)]),
            "category": .string("pantry"), "date": .string(date), "createdAt": .string("\(date)T12:00:00Z"),
        ]
        if bill {
            fields["bill"] = .object([
                "billId": .string("77777777-7777-4777-8777-777777777777"),
                "month": .string(String(date.prefix(7))), "dueDate": .string(date),
            ])
        }
        return .object(fields)
    }

    private static func snapshot(_ expenses: [JSONValue], zone: String? = nil) throws -> HouseholdSnapshot {
        var changes: [String: JSONValue] = [:]
        if let zone { changes["billingTimeZone"] = .string(zone) }
        let value = ShoppingFixtures.replacing(LedgerFixtures.household(expenses: expenses), with: changes)
        return try ShoppingFixtures.snapshot(value)
    }

    @Test
    func countsOnlyThisMonthsGroceriesAgainstTheBudget() throws {
        let household = try Self.snapshot([
            Self.expense("10000000-0000-4000-8000-000000000001", amount: 2_500, date: "2026-10-03"),
            Self.expense("10000000-0000-4000-8000-000000000002", amount: 1_000, date: "2026-10-20"),
            Self.expense("10000000-0000-4000-8000-000000000003", amount: 9_999, date: "2026-09-30"),
            Self.expense("10000000-0000-4000-8000-000000000004", amount: 4_200, date: "2026-10-05", bill: true),
        ], zone: "Europe/Amsterdam")
        let now = ISO8601DateFormatter().date(from: "2026-10-21T22:00:00Z")!
        let pot = try HousePot(household: household, now: now)
        #expect(pot.spent == 3_500)
        #expect(pot.remaining == pot.budget - 3_500)
        #expect(pot.currency == household.currency)
    }

    @Test
    func theMonthFollowsTheHouseholdTimeZone() throws {
        let late = ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z")!
        #expect(HousePot.month(of: late, in: try HouseholdTimeZone(identifier: "UTC")) == "2026-10")
        #expect(HousePot.month(of: late, in: try HouseholdTimeZone(identifier: "Europe/Amsterdam")) == "2026-11")
        #expect(HousePot.month(of: late, in: try HouseholdTimeZone(identifier: "-05:00")) == "2026-10")
    }
}
