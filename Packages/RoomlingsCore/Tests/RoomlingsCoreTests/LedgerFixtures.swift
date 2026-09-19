import Foundation
@testable import RoomlingsCore

enum LedgerFixtures {
    static let checkoutID = UUID(uuidString: "12121212-1212-4121-8121-121212121212")!
    static let recordedID = UUID(uuidString: "13131313-1313-4131-8131-131313131313")!
    static let plainExpenseID = UUID(uuidString: "14141414-1414-4141-8141-141414141414")!
    static let runExpenseID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
    static let createdAt = "2026-09-18T12:00:00.000Z"
    static let date = "2026-09-18"

    static func id(_ value: UUID) -> JSONValue { ShoppingFixtures.id(value) }

    /// A plain expense that the native sheet is allowed to remove.
    static var plainExpense: JSONValue {
        .object([
            "id": id(plainExpenseID), "description": .string("Corner shop"), "amount": .integer(450),
            "paidBy": id(ShoppingFixtures.memberID),
            "participants": .array([id(ShoppingFixtures.memberID), id(ShoppingFixtures.roommateID)]),
            "category": .string("pantry"), "date": .string("2026-09-10"),
            "createdAt": .string("2026-09-10T12:00:00Z"), "futureExpenseData": .integer(Int64.max)
        ])
    }

    static var draft: ExpenseDraft {
        try! ExpenseDraft(
            description: "  Weekly groceries  ", amount: 2_599, paidBy: ShoppingFixtures.memberID,
            participants: [ShoppingFixtures.memberID, ShoppingFixtures.roommateID],
            category: .produce, date: date
        )
    }

    static var requestFields: [String: JSONValue] {
        [
            "description": .string("Weekly groceries"), "amount": .integer(2_599),
            "paidBy": id(ShoppingFixtures.memberID),
            "participants": .array([id(ShoppingFixtures.memberID), id(ShoppingFixtures.roommateID)]),
            "category": .string("produce"), "date": .string(date)
        ]
    }

    /// The saved form of `draft`, as the server unshifts it onto the ledger.
    static func saved(runID: UUID? = nil, id savedID: UUID = recordedID) -> JSONValue {
        var fields = requestFields
        fields["id"] = id(savedID)
        fields["createdAt"] = .string(createdAt)
        if let runID { fields["shoppingRunId"] = id(runID) }
        return .object(fields)
    }

    static func household(
        items: [JSONValue] = [ShoppingFixtures.item, ShoppingFixtures.otherItem],
        expenses: [JSONValue]? = nil, runs: [JSONValue]? = nil, version: Int64 = 17
    ) -> JSONValue {
        var changes: [String: JSONValue] = [
            "version": .integer(version),
            "shopping": .object([
                "items": .array(items), "runs": .array(runs ?? ShoppingFixtures.runs),
                "futureShoppingData": .integer(Int64.max)
            ])
        ]
        let base = ShoppingFixtures.household(items: items, version: version)
        changes["expenses"] = .array(expenses ?? ((base["expenses"]?.arrayValue ?? []) + [plainExpense]))
        return ShoppingFixtures.replacing(base, with: changes)
    }

    static func state(household value: JSONValue = household()) -> [String: JSONValue] {
        ShoppingFixtures.state(household: value)
    }

    static func projection(_ value: JSONValue = household()) throws -> HouseholdLedger {
        try HouseholdLedger(household: ShoppingFixtures.snapshot(value))
    }

    /// The household returned after recording a standalone expense.
    static func recorded() -> JSONValue {
        let expenses = (household()["expenses"]?.arrayValue ?? [])
        return ShoppingFixtures.withReceipt(
            household(expenses: [saved()] + expenses, version: 18)
        )
    }

    /// The household returned after a basket checkout removes the claimed item.
    static func checkedOut(itemID: UUID = ShoppingFixtures.itemID) -> JSONValue {
        let remaining = [ShoppingFixtures.otherItem]
        let expenses = (household()["expenses"]?.arrayValue ?? [])
        let run = JSONValue.object([
            "id": id(checkoutID), "expenseId": id(recordedID), "name": .string("Weekly groceries"),
            "completedBy": id(ShoppingFixtures.memberID), "completedAt": .string(createdAt),
            "items": .array([.object([
                "id": id(itemID), "name": .string("Milk"), "quantity": .string("2 cartons"),
                "notes": .string("Unsweetened"), "createdBy": id(ShoppingFixtures.roommateID),
                "createdAt": .string("2026-09-01T12:00:00Z"), "componentSources": .array([ShoppingFixtures.source])
            ])])
        ])
        return ShoppingFixtures.withReceipt(household(
            items: remaining, expenses: [saved(runID: checkoutID)] + expenses,
            runs: ShoppingFixtures.runs + [run], version: 18
        ))
    }

    /// The household returned after removing the plain expense.
    static func removed() -> JSONValue {
        let expenses = (household()["expenses"]?.arrayValue ?? []).filter {
            $0["id"]?.stringValue != plainExpenseID.uuidString.lowercased()
        }
        return ShoppingFixtures.withReceipt(household(expenses: expenses, version: 18))
    }
}
