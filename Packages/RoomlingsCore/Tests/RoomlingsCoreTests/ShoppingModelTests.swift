import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native shopping projection")
struct ShoppingModelTests {
    @Test
    func exposesAndAcceptsTheSharedItemLimit() throws {
        #expect(HouseholdShopping.itemLimit == 200)
        let items = (0..<HouseholdShopping.itemLimit).map { _ in
            ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["id": ShoppingFixtures.id(UUID())])
        }
        #expect(try ShoppingFixtures.projection(items: items).items.count == HouseholdShopping.itemLimit)
        #expect(throws: AccountError.invalidResponse) {
            try ShoppingFixtures.projection(items: items + [ShoppingFixtures.item])
        }
    }

    @Test
    func projectsSharedItemsAndRetainedOwnersWithoutRewritingAnyLedgerData() throws {
        let raw = ShoppingFixtures.household()
        let household = try ShoppingFixtures.snapshot(raw)
        let shopping = try HouseholdShopping(household: household)
        let item = try #require(shopping.items.first)
        #expect(item.id == ShoppingFixtures.itemID)
        #expect(item.name == "Milk")
        #expect(item.quantity == "2 cartons")
        #expect(item.notes == "Unsweetened")
        #expect(item.version == 4)
        #expect(item.createdBy == ShoppingFixtures.roommateID)
        #expect(item.claimedBy == nil)
        #expect(!item.pickedUp)
        #expect(item.createdAt == "2026-09-01T12:00:00Z")
        #expect(item.updatedAt == "2026-09-15T12:00:00.000Z")
        let source = try #require(item.componentSources?.first)
        #expect(source.componentID == "default-kitchen-sink")
        #expect(source.supplyID == "dish-soap")
        #expect(source.roomID == "kitchen")
        #expect(source.componentName == "The old sink name")
        #expect(shopping.activeMembers.map(\.id) == [ShoppingFixtures.memberID, ShoppingFixtures.roommateID])
        #expect(shopping.members.map(\.name) == ["Alex", "Alex", "Alex"])
        #expect(shopping.members.map(\.color) == ["#7d9070", "#c9533a", "#7c89a1"])
        let retained = try #require(shopping.items.last)
        #expect(shopping.claimOwner(for: retained)?.id == ShoppingFixtures.inactiveID)
        #expect(shopping.claimOwner(for: retained)?.inactive == true)
        #expect(shopping.inBasket(retained, memberID: ShoppingFixtures.inactiveID))
        #expect(household.value == raw)
        #expect(household.value["expenses"]?.arrayValue?.first?["amount"] == .integer(1_999))
        #expect(household.value["shopping"]?["runs"] == .array(ShoppingFixtures.runs))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(household))
        #expect(encoded == raw)
        #expect(encoded["unrecognizedServerField"] == .integer(9_007_199_254_740_993))
        #expect(encoded["shopping"]?["items"]?.arrayValue?.first?["componentSources"]?.arrayValue?.first?["futureSourceData"] == .integer(Int64.max))
    }

    @Test
    func onlyAbsentLegacyFieldsReceiveTheSharedDefaults() throws {
        let old = try ShoppingFixtures.snapshot(Fixtures.household)
        let shopping = try HouseholdShopping(household: old)
        #expect(shopping.items.isEmpty)
        #expect(shopping.members.first?.inactive == false)
        #expect(old.value["shopping"] == nil)
        var raw = ShoppingFixtures.item
        for field in ["quantity", "notes", "componentSources"] {
            raw = ShoppingFixtures.removing(field, from: raw)
        }
        let projection = try ShoppingFixtures.projection(items: [raw])
        let item = try #require(projection.items.first)
        #expect(item.quantity == "1")
        #expect(item.notes == "")
        #expect(item.componentSources == nil)
        #expect(raw["quantity"] == nil)
    }

    @Test
    func draftsUseSharedTrimAndUTF16LimitsWithoutMergingNames() throws {
        let draft = try ShoppingDraft(name: "\u{FEFF}  Milk \u{3000}", quantity: "\n2 cartons ", notes: "\u{FEFF} Plain ")
        #expect(draft.name == "Milk")
        #expect(draft.quantity == "2 cartons")
        #expect(draft.notes == "Plain")
        let defaults = try ShoppingDraft(name: "Ｓｏａｐ")
        #expect(defaults.name == "Ｓｏａｐ")
        #expect(defaults.quantity == "1")
        #expect(defaults.notes == "")
        #expect(try ShoppingDraft(name: "\u{0085}", quantity: "\u{0085}").name == "\u{0085}")
        let maximum = try ShoppingDraft(
            name: String(repeating: "🥛", count: 25), quantity: String(repeating: "🥛", count: 20),
            notes: String(repeating: "🥛", count: 120)
        )
        #expect(maximum.name.utf16.count == 50)
        #expect(maximum.quantity.utf16.count == 40)
        #expect(maximum.notes.utf16.count == 240)
        let duplicate = ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["id": ShoppingFixtures.id(ShoppingFixtures.addedID)])
        #expect(try ShoppingFixtures.projection(items: [ShoppingFixtures.item, duplicate]).items.count == 2)
    }

    @Test(arguments: [
        ("", "1", "", AccountInputField.name), (" \u{FEFF}", "1", "", .name),
        (String(repeating: "🥛", count: 26), "1", "", .name),
        ("Milk", "", "", .quantity), ("Milk", "\u{3000}", "", .quantity),
        ("Milk", String(repeating: "🥛", count: 21), "", .quantity),
        ("Milk", "1", String(repeating: "🥛", count: 121), .notes)
    ])
    func rejectsInvalidDrafts(name: String, quantity: String, notes: String, field: AccountInputField) {
        #expect(throws: AccountError.invalidInput(field)) {
            try ShoppingDraft(name: name, quantity: quantity, notes: notes)
        }
    }

    @Test(arguments: ["id", "name", "version", "createdBy", "claimedBy", "pickedUp", "createdAt", "updatedAt"])
    func requiredItemFieldsCannotBecomeDefaults(field: String) {
        #expect(throws: AccountError.invalidResponse) {
            try ShoppingFixtures.projection(items: [ShoppingFixtures.removing(field, from: ShoppingFixtures.item)])
        }
    }

    @Test(arguments: [
        ("id", JSONValue.string("invalid")), ("id", .string("11111111-1111-9111-8111-111111111111")),
        ("name", .string(" \u{FEFF}")), ("name", .string(String(repeating: "x", count: 51))),
        ("name", .null), ("quantity", .null), ("quantity", .string("")),
        ("quantity", .string(String(repeating: "x", count: 41))), ("notes", .null),
        ("notes", .string(String(repeating: "x", count: 241))),
        ("version", .integer(-1)), ("version", .integer(Int64.max)), ("version", .number(1.5)), ("version", .bool(false)),
        ("createdBy", .string("bad")), ("claimedBy", .string("bad")), ("claimedBy", .bool(false)),
        ("pickedUp", .string("false")), ("pickedUp", .bool(true)),
        ("createdAt", .string("2026-02-30T12:00:00Z")), ("createdAt", .string("2026-09-17")),
        ("updatedAt", .string("2026-09-17T12:00:00+01:00")), ("updatedAt", .string("2026-09-17T24:01:00Z")),
        ("componentSources", .null), ("componentSources", .object([:])), ("componentSources", .array([.null]))
    ])
    func rejectsMalformedItemValues(key: String, value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            try ShoppingFixtures.projection(items: [ShoppingFixtures.replacing(ShoppingFixtures.item, with: [key: value])])
        }
    }

    @Test(arguments: [
        JSONValue.null, .array([]), .object([:]), .object(["items": .array([])]),
        .object(["items": .array([]), "runs": .null]), .object(["items": .array([.null]), "runs": .array([])])
    ])
    func malformedCollectionsNeverBecomeAnEmptyList(value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            try HouseholdShopping(household: ShoppingFixtures.snapshot(ShoppingFixtures.replacing(
                ShoppingFixtures.household(), with: ["shopping": value]
            )))
        }
    }

    @Test(arguments: ["duplicate-item", "unknown-creator", "unknown-owner", "too-many-items", "too-many-runs", "too-many-active"])
    func rejectsInvalidSharedRelationshipsAndLimits(kind: String) {
        var household = ShoppingFixtures.household()
        switch kind {
        case "duplicate-item":
            household = ShoppingFixtures.household(items: [ShoppingFixtures.item, ShoppingFixtures.item])
        case "unknown-creator", "unknown-owner":
            household = ShoppingFixtures.household(items: [ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
                kind == "unknown-creator" ? "createdBy" : "claimedBy": ShoppingFixtures.id(UUID())
            ])])
        case "too-many-items":
            household = ShoppingFixtures.household(items: (0...200).map { _ in
                ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["id": ShoppingFixtures.id(UUID())])
            })
        case "too-many-runs":
            household = ShoppingFixtures.replacing(household, with: ["shopping": .object([
                "items": .array([]), "runs": .array(Array(repeating: ShoppingFixtures.runs[0], count: 20_001))
            ])])
        default:
            let members = (0..<13).map { _ in ShoppingFixtures.replacing(ShoppingFixtures.members[0], with: ["id": ShoppingFixtures.id(UUID())]) }
            household = ShoppingFixtures.replacing(ShoppingFixtures.household(items: []), with: ["members": .array(members)])
        }
        #expect(throws: AccountError.invalidResponse) {
            try HouseholdShopping(household: ShoppingFixtures.snapshot(household))
        }
    }

    @Test
    func sourcesKeepHistoricalNamesEvenWhenObjectsAreStoredRenamedOrNoLongerOfferTheSupply() throws {
        let source = ShoppingFixtures.replacing(ShoppingFixtures.source, with: [
            "componentId": .string("saved-object"), "roomId": .string("living-room"), "supplyId": .string("retired-supply")
        ])
        let rawItem = ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["componentSources": .array([source])])
        let component = ChoreFixtures.component(installed: false)
        let raw = ShoppingFixtures.replacing(ShoppingFixtures.household(items: [rawItem]), with: [
            "roomComponents": .array([component]), "expenses": .array([]),
            "shopping": .object(["items": .array([rawItem]), "runs": .array([])])
        ])
        let household = try ShoppingFixtures.snapshot(raw)
        let shopping = try HouseholdShopping(household: household)
        #expect(shopping.items.first?.componentSources?.first?.componentName == "The old sink name")
        #expect(shopping.items.first?.componentSources?.first?.supplyID == "retired-supply")
        #expect(shopping.canEdit(try #require(shopping.items.first), memberID: ShoppingFixtures.memberID))
        #expect(household.value == raw)
        let migratedSource = ShoppingFixtures.replacing(source, with: ["componentId": .string("default-living-room-supply-shelf")])
        let migrated = ShoppingFixtures.replacing(raw, with: [
            "roomComponents": .array([]), "shopping": .object([
                "items": .array([ShoppingFixtures.replacing(rawItem, with: ["componentSources": .array([migratedSource])])]),
                "runs": .array([])
            ])
        ])
        #expect(try HouseholdShopping(household: ShoppingFixtures.snapshot(migrated)).items.count == 1)
    }

    @Test(arguments: [
        ("componentId", JSONValue.string("missing-object")), ("componentId", .string("Not a slug")),
        ("supplyId", .string("")), ("supplyId", .string(String(repeating: "a", count: 81))), ("supplyId", .null),
        ("roomId", .string("bathroom")), ("roomId", .string("attic")),
        ("componentName", .null), ("componentName", .string(" ")), ("componentName", .string(String(repeating: "a", count: 51)))
    ])
    func rejectsMalformedOrForeignComponentSources(key: String, value: JSONValue) {
        let source = ShoppingFixtures.replacing(ShoppingFixtures.source, with: [key: value])
        #expect(throws: AccountError.invalidResponse) {
            try ShoppingFixtures.projection(items: [
                ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["componentSources": .array([source])])
            ])
        }
    }

    @Test
    func sourceReferencesAreDistinctPerObjectAndSupplyAndRespectTheSharedLimit() throws {
        let second = ShoppingFixtures.replacing(ShoppingFixtures.source, with: ["supplyId": .string("sponges")])
        let item = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
            "componentSources": .array([ShoppingFixtures.source, second])
        ])
        #expect(try ShoppingFixtures.projection(items: [item]).items.first?.componentSources?.count == 2)
        for sources in [
            [ShoppingFixtures.source, ShoppingFixtures.source],
            (0..<161).map { ShoppingFixtures.replacing(ShoppingFixtures.source, with: ["supplyId": .string("supply-\($0)")]) }
        ] {
            #expect(throws: AccountError.invalidResponse) {
                try ShoppingFixtures.projection(items: [ShoppingFixtures.replacing(item, with: ["componentSources": .array(sources)])])
            }
        }
    }

    @Test
    func permissionsUseMemberIdentityAndSharedClaimBasketRules() throws {
        let actors = [ShoppingFixtures.memberID, ShoppingFixtures.roommateID, ShoppingFixtures.inactiveID, UUID()]
        let owners: [UUID?] = [nil, ShoppingFixtures.memberID, ShoppingFixtures.roommateID, ShoppingFixtures.inactiveID]
        for owner in owners {
            for pickedUp in [false, true] where !pickedUp || owner != nil {
                let item = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
                    "claimedBy": owner.map(ShoppingFixtures.id) ?? .null, "pickedUp": .bool(pickedUp)
                ])
                let shopping = try ShoppingFixtures.projection(items: [item])
                let current = try #require(shopping.items.first)
                for actor in actors {
                    let active = actor == ShoppingFixtures.memberID || actor == ShoppingFixtures.roommateID
                    let owns = owner == nil || owner == actor
                    #expect(shopping.canEdit(current, memberID: actor) == (active && !pickedUp && owns))
                    #expect(shopping.inBasket(current, memberID: actor) == (pickedUp && owner == actor))
                    #expect(shopping.canClaim(current, claim: true, memberID: actor) == (active && owner == nil))
                    #expect(shopping.canClaim(current, claim: false, memberID: actor) == (active && owner != nil))
                    #expect(shopping.canPick(current, pickedUp: true, memberID: actor) == (active && !pickedUp && owns))
                    #expect(shopping.canPick(current, pickedUp: false, memberID: actor) == (active && pickedUp && owns))
                }
            }
        }
    }

    @Test
    func staleOrRemovedItemValuesAreNotOfferedAsNewActions() throws {
        let old = try #require(ShoppingFixtures.projection().items.first)
        let changed = ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["version": .integer(5)])
        for shopping in [try ShoppingFixtures.projection(items: [changed]), try ShoppingFixtures.projection(items: [])] {
            #expect(!shopping.canEdit(old, memberID: ShoppingFixtures.memberID))
            #expect(!shopping.canClaim(old, claim: true, memberID: ShoppingFixtures.memberID))
            #expect(!shopping.canPick(old, pickedUp: true, memberID: ShoppingFixtures.memberID))
        }
    }

    @Test
    func retainedRunsSurviveDeletedReceiptsWithoutInventingDebtOrDefaultingRawFields() throws {
        let archived = try #require(ShoppingFixtures.runs.first?["items"]?.arrayValue?.first)
        let legacy = ShoppingFixtures.removing("quantity", from: ShoppingFixtures.removing("notes", from: archived))
        let run = ShoppingFixtures.replacing(ShoppingFixtures.runs[0], with: ["items": .array([legacy])])
        let raw = ShoppingFixtures.replacing(ShoppingFixtures.household(), with: [
            "expenses": .array([]), "shopping": .object([
                "items": .array([ShoppingFixtures.item]), "runs": .array([run])
            ])
        ])
        let household = try ShoppingFixtures.snapshot(raw)
        #expect(try HouseholdShopping(household: household).items.count == 1)
        #expect(household.value == raw)
        #expect(household.value["expenses"] == .array([]))
        #expect(household.value["shopping"]?["runs"]?.arrayValue?.first?["items"]?.arrayValue?.first?["quantity"] == nil)
    }

    @Test(arguments: [
        "null-run", "empty-run", "missing-field", "unknown-shopper", "duplicate-run", "duplicate-receipt", "duplicate-item",
        "invalid-archived-item", "unknown-archived-author", "wrong-source-room", "unrelated-receipt", "unknown-payer",
        "unknown-participant", "bill-receipt", "unlinked-receipt"
    ])
    func malformedRetainedShoppingDataCannotHideInsideAValidList(kind: String) throws {
        var runs = ShoppingFixtures.runs
        var expenses = try #require(ShoppingFixtures.household()["expenses"]?.arrayValue)
        let archived = try #require(runs.first?["items"]?.arrayValue?.first)
        switch kind {
        case "null-run": runs = [.null]
        case "empty-run": runs = [ShoppingFixtures.replacing(runs[0], with: ["items": .array([])])]
        case "missing-field": runs = [ShoppingFixtures.removing("expenseId", from: runs[0])]
        case "unknown-shopper": runs = [ShoppingFixtures.replacing(runs[0], with: ["completedBy": ShoppingFixtures.id(UUID())])]
        case "duplicate-run": runs.append(runs[0])
        case "duplicate-receipt": runs.append(ShoppingFixtures.replacing(runs[0], with: ["id": ShoppingFixtures.id(UUID())]))
        case "duplicate-item": runs = [ShoppingFixtures.replacing(runs[0], with: ["items": .array([ShoppingFixtures.item])])]
        case "invalid-archived-item": runs = [ShoppingFixtures.replacing(runs[0], with: ["items": .array([.null])])]
        case "unknown-archived-author":
            runs = [ShoppingFixtures.replacing(runs[0], with: ["items": .array([
                ShoppingFixtures.replacing(archived, with: ["createdBy": ShoppingFixtures.id(UUID())])
            ])])]
        case "wrong-source-room":
            let source = ShoppingFixtures.replacing(ShoppingFixtures.source, with: ["roomId": .string("bathroom")])
            runs = [ShoppingFixtures.replacing(runs[0], with: ["items": .array([
                ShoppingFixtures.replacing(archived, with: ["componentSources": .array([source])])
            ])])]
        case "unrelated-receipt": expenses[0] = ShoppingFixtures.replacing(expenses[0], with: ["shoppingRunId": ShoppingFixtures.id(UUID())])
        case "unknown-payer": expenses[0] = ShoppingFixtures.replacing(expenses[0], with: ["paidBy": ShoppingFixtures.id(UUID())])
        case "unknown-participant":
            expenses[0] = ShoppingFixtures.replacing(expenses[0], with: ["participants": .array([ShoppingFixtures.id(UUID())])])
        case "bill-receipt": expenses[0] = ShoppingFixtures.replacing(expenses[0], with: ["bill": .object([:])])
        default: expenses[0] = ShoppingFixtures.removing("shoppingRunId", from: expenses[0])
        }
        let raw = ShoppingFixtures.replacing(ShoppingFixtures.household(), with: [
            "expenses": .array(expenses), "shopping": .object(["items": .array([ShoppingFixtures.item]), "runs": .array(runs)])
        ])
        #expect(throws: AccountError.invalidResponse) { try HouseholdShopping(household: ShoppingFixtures.snapshot(raw)) }
    }
}
