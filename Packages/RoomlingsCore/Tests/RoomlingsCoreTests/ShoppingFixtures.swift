import Foundation
@testable import RoomlingsCore

enum ShoppingFixtures {
    static let householdID = UUID(uuidString: Fixtures.householdID)!
    static let memberID = UUID(uuidString: Fixtures.memberID)!
    static let roommateID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let inactiveID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let itemID = UUID(uuidString: "aabbccdd-aabb-4ccd-8abb-aabbccddeeff")!
    static let otherItemID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    static let addedID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    static let mutationID = UUID(uuidString: "ddeeffaa-ddee-4ffa-8dde-aabbccddeeff")!
    static let undoMutationID = UUID(uuidString: "ddeeffab-ddee-4ffa-8dde-aabbccddeeff")!
    static let updatedAt = "2026-09-17T12:00:00.000Z"

    static func id(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }

    static var draft: ShoppingDraft {
        try! ShoppingDraft(name: "  Milk  ", quantity: " 3 cartons ", notes: "\nPlain ")
    }

    static var members: [JSONValue] {
        [
            .object(["id": id(memberID), "name": .string("Alex"), "color": .string("#7d9070")]),
            .object(["id": id(roommateID), "name": .string("Alex"), "color": .string("#c9533a"), "inactive": .bool(false)]),
            .object(["id": id(inactiveID), "name": .string("Alex"), "color": .string("#7c89a1"), "inactive": .bool(true)])
        ]
    }

    static var source: JSONValue {
        .object([
            "componentId": .string("default-kitchen-sink"), "supplyId": .string("dish-soap"),
            "roomId": .string("kitchen"), "componentName": .string("The old sink name"),
            "futureSourceData": .integer(Int64.max)
        ])
    }

    static var item: JSONValue {
        .object([
            "id": id(itemID), "name": .string("Milk"), "quantity": .string("2 cartons"), "notes": .string("Unsweetened"),
            "version": .integer(4), "createdBy": id(roommateID), "claimedBy": .null, "pickedUp": .bool(false),
            "createdAt": .string("2026-09-01T12:00:00Z"), "updatedAt": .string("2026-09-15T12:00:00.000Z"),
            "componentSources": .array([source]), "futureItemData": .object(["maximum": .integer(Int64.max)])
        ])
    }

    static var otherItem: JSONValue {
        replacing(item, with: [
            "id": id(otherItemID), "name": .string("Bread"), "createdBy": id(inactiveID),
            "claimedBy": id(inactiveID), "pickedUp": .bool(true), "componentSources": .array([])
        ])
    }

    static var runs: [JSONValue] {
        [.object([
            "id": .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"),
            "expenseId": .string("ffffffff-ffff-4fff-8fff-ffffffffffff"),
            "name": .string("Previous run"), "completedBy": id(inactiveID),
            "completedAt": .string("2026-09-01T12:00:00Z"),
            "items": .array([.object([
                "id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "name": .string("Dish soap"),
                "quantity": .string("1"), "notes": .string(""), "createdBy": id(inactiveID),
                "createdAt": .string("2026-09-01T11:00:00Z"), "componentSources": .array([source])
            ])]),
            "futureRunData": .integer(Int64.max)
        ])]
    }

    static func household(items: [JSONValue] = [item, otherItem], version: Int64 = 17) -> JSONValue {
        replacing(Fixtures.household, with: [
            "members": .array(members), "version": .integer(version),
            "shopping": .object(["items": .array(items), "runs": .array(runs), "futureShoppingData": .integer(Int64.max)]),
            "expenses": .array([.object([
                "id": .string("ffffffff-ffff-4fff-8fff-ffffffffffff"), "description": .string("Previous run"),
                "amount": .integer(1_999), "paidBy": id(inactiveID), "participants": .array([id(memberID), id(inactiveID)]),
                "category": .string("other"), "date": .string("2026-09-01"), "createdAt": .string("2026-09-01T12:00:00Z"),
                "shoppingRunId": .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"),
                "futureExpenseData": .integer(Int64.max)
            ])]),
            "mutationReceipts": .array([]),
            "futureServerData": .object(["maximum": .integer(Int64.max), "fraction": .number(1.25)])
        ])
    }

    static func state(household: JSONValue = household(), role: AccountRole = .owner) -> [String: JSONValue] {
        var object = Fixtures.state(selectedHousehold: true)
        object["session"] = .object(["token": .null, "memberId": id(memberID), "household": household])
        object["memberships"] = .array([replacing(Fixtures.membership, with: ["role": .string(role.rawValue)])])
        return object
    }

    static func withReceipt(_ household: JSONValue) -> JSONValue {
        replacing(household, with: ["mutationReceipts": .array([.object([
            "id": id(mutationID), "memberId": id(memberID), "version": .integer(18),
            "fingerprint": .string(String(repeating: "1", count: 64)), "futureReceiptData": .integer(Int64.max)
        ])])])
    }

    static func projection(items: [JSONValue] = [item, otherItem]) throws -> HouseholdShopping {
        try HouseholdShopping(household: snapshot(household(items: items)))
    }

    static func snapshot(_ value: JSONValue) throws -> HouseholdSnapshot {
        try ChoreFixtures.snapshot(value)
    }

    static func replacing(_ value: JSONValue, with changes: [String: JSONValue]) -> JSONValue {
        ChoreFixtures.replacing(value, with: changes)
    }

    static func removing(_ key: String, from value: JSONValue) -> JSONValue {
        ChoreFixtures.removing(key, from: value)
    }
}

enum ShoppingOperation: CaseIterable, Sendable {
    case add, edit, remove, claim, release, pick, unpick

    var initialItem: JSONValue {
        switch self {
        case .release:
            ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
                "claimedBy": ShoppingFixtures.id(ShoppingFixtures.roommateID), "pickedUp": .bool(true)
            ])
        case .unpick:
            ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
                "claimedBy": ShoppingFixtures.id(ShoppingFixtures.memberID), "pickedUp": .bool(true)
            ])
        default: ShoppingFixtures.item
        }
    }

    var initialHousehold: JSONValue {
        ShoppingFixtures.household(items: [initialItem, ShoppingFixtures.otherItem])
    }

    var successHousehold: JSONValue {
        var items = [initialItem, ShoppingFixtures.otherItem]
        switch self {
        case .add:
            items.append(.object(ShoppingFixtures.draft.requestFields.merging([
                "id": ShoppingFixtures.id(ShoppingFixtures.addedID), "createdBy": ShoppingFixtures.id(ShoppingFixtures.memberID),
                "createdAt": .string(ShoppingFixtures.updatedAt), "updatedAt": .string(ShoppingFixtures.updatedAt),
                "version": .integer(0), "claimedBy": .null, "pickedUp": .bool(false)
            ]) { _, new in new }))
        case .remove:
            items.removeFirst()
        default:
            var fields: [String: JSONValue] = ["version": .integer(5), "updatedAt": .string(ShoppingFixtures.updatedAt)]
            switch self {
            case .edit: fields.merge(ShoppingFixtures.draft.requestFields) { _, new in new }
            case .claim: fields["claimedBy"] = ShoppingFixtures.id(ShoppingFixtures.memberID)
            case .release: fields.merge(["claimedBy": .null, "pickedUp": .bool(false)]) { _, new in new }
            case .pick:
                fields.merge(["claimedBy": ShoppingFixtures.id(ShoppingFixtures.memberID), "pickedUp": .bool(true)]) { _, new in new }
            case .unpick: fields["pickedUp"] = .bool(false)
            default: break
            }
            items[0] = ShoppingFixtures.replacing(initialItem, with: fields)
        }
        return ShoppingFixtures.withReceipt(ShoppingFixtures.household(items: items, version: 18))
    }

    var path: String {
        let item = "/api/shopping/items/\(ShoppingFixtures.itemID.uuidString.lowercased())"
        return switch self {
        case .add: "/api/shopping/items"
        case .edit, .remove: item
        case .claim, .release: "\(item)/claim"
        case .pick, .unpick: "\(item)/pick"
        }
    }

    var method: String {
        switch self {
        case .edit: "PATCH"
        case .remove: "DELETE"
        default: "POST"
        }
    }

    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = self == .add ? [:] : ["itemVersion": .integer(4)]
        switch self {
        case .add, .edit:
            fields.merge(["name": .string("Milk"), "quantity": .string("3 cartons"), "notes": .string("Plain")]) { _, new in new }
        case .claim, .release: fields["claimed"] = .bool(self == .claim)
        case .pick, .unpick: fields["pickedUp"] = .bool(self == .pick)
        case .remove: break
        }
        return fields
    }

    @discardableResult
    func perform(
        _ session: AccountSession, householdID: UUID = ShoppingFixtures.householdID,
        version: Int64 = 17, mutationID: UUID = ShoppingFixtures.mutationID, itemVersion: Int64 = 4
    ) async throws -> AccountState {
        switch self {
        case .add:
            try await session.addShoppingItem(
                ShoppingFixtures.draft, householdID: householdID, version: version, mutationID: mutationID
            )
        case .edit:
            try await session.editShoppingItem(
                id: ShoppingFixtures.itemID, draft: ShoppingFixtures.draft, itemVersion: itemVersion,
                householdID: householdID, version: version, mutationID: mutationID
            )
        case .remove:
            try await session.removeShoppingItem(
                id: ShoppingFixtures.itemID, itemVersion: itemVersion,
                householdID: householdID, version: version, mutationID: mutationID
            )
        case .claim, .release:
            try await session.claimShoppingItem(
                id: ShoppingFixtures.itemID, claim: self == .claim, itemVersion: itemVersion,
                householdID: householdID, version: version, mutationID: mutationID
            )
        case .pick, .unpick:
            try await session.pickShoppingItem(
                id: ShoppingFixtures.itemID, pickedUp: self == .pick, itemVersion: itemVersion,
                householdID: householdID, version: version, mutationID: mutationID
            )
        }
    }
}
