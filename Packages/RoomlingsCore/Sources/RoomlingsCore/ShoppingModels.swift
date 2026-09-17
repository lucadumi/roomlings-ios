import Foundation

public struct ShoppingDraft: Sendable, Equatable {
    public let name: String
    public let quantity: String
    public let notes: String

    public init(name: String, quantity: String = "1", notes: String = "") throws {
        guard let name = HouseholdValidation.text(name, length: 1...50) else {
            throw AccountError.invalidInput(.name)
        }
        guard let quantity = HouseholdValidation.text(quantity, length: 1...40) else {
            throw AccountError.invalidInput(.quantity)
        }
        guard let notes = HouseholdValidation.text(notes, length: 0...240) else {
            throw AccountError.invalidInput(.notes)
        }
        self.name = name
        self.quantity = quantity
        self.notes = notes
    }

    var requestFields: [String: JSONValue] {
        ["name": .string(name), "quantity": .string(quantity), "notes": .string(notes)]
    }
}

public struct ShoppingComponentSource: Sendable, Equatable, Hashable {
    public let componentID: String
    public let supplyID: String
    public let roomID: String
    public let componentName: String

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        componentID = try fields.string("componentId")
        supplyID = try fields.string("supplyId")
        roomID = try fields.string("roomId")
        componentName = try fields.text("componentName", length: 1...50)
        guard HouseholdValidation.componentID(componentID), HouseholdValidation.componentID(supplyID),
              ChoreValidation.areas[roomID] != nil else { throw AccountError.invalidResponse }
    }
}

public struct ShoppingItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let quantity: String
    public let notes: String
    public let version: Int64
    public let createdBy: UUID
    public let claimedBy: UUID?
    public let pickedUp: Bool
    public let createdAt: String
    public let updatedAt: String
    public let componentSources: [ShoppingComponentSource]?

    init(_ value: JSONValue) throws {
        let snapshot = try ShoppingItemSnapshot(value)
        id = snapshot.id
        name = snapshot.name
        quantity = snapshot.quantity
        notes = snapshot.notes
        createdBy = snapshot.createdBy
        createdAt = snapshot.createdAt
        componentSources = snapshot.componentSources
        let fields = try HouseholdFields(value)
        version = try fields.integer("version")
        claimedBy = try fields.nullableUUID("claimedBy")
        pickedUp = try fields.bool("pickedUp")
        updatedAt = try fields.timestamp("updatedAt")
        guard !pickedUp || claimedBy != nil else { throw AccountError.invalidResponse }
    }
}

private struct ShoppingItemSnapshot {
    let id: UUID
    let name: String
    let quantity: String
    let notes: String
    let createdBy: UUID
    let createdAt: String
    let componentSources: [ShoppingComponentSource]?

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.uuid("id")
        name = try fields.text("name", length: 1...50)
        quantity = try fields.text("quantity", length: 1...40, default: "1")
        notes = try fields.text("notes", length: 0...240, default: "")
        createdBy = try fields.uuid("createdBy")
        createdAt = try fields.timestamp("createdAt")
        if fields.object["componentSources"] != nil {
            let rawSources = try fields.array("componentSources")
            guard rawSources.count <= 160 else { throw AccountError.invalidResponse }
            componentSources = try rawSources.map(ShoppingComponentSource.init)
        } else {
            componentSources = nil
        }
    }
}

/// A read-only projection of the shared list, not a basket ledger or a checkout calculation.
public struct HouseholdShopping: Sendable, Equatable {
    public static let itemLimit = 200

    public let items: [ShoppingItem]
    public let members: [HouseholdMember]
    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    let householdVersion: Int64

    public init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        let memberIDs = Set(members.map(\.id))
        let components = try HouseholdComponent.projection(household: household.value)
        let rawRuns: [JSONValue]
        if let shopping = household.value["shopping"] {
            let fields = try HouseholdFields(shopping)
            let rawItems = try fields.array("items")
            rawRuns = try fields.array("runs")
            guard rawItems.count <= Self.itemLimit, rawRuns.count <= 20_000 else {
                throw AccountError.invalidResponse
            }
            items = try rawItems.map(ShoppingItem.init)
        } else {
            // Only an absent shopping field has the shared legacy empty-list default.
            items = []
            rawRuns = []
        }
        var itemIDs = Set<UUID>()
        for item in items {
            guard itemIDs.insert(item.id).inserted, memberIDs.contains(item.createdBy),
                  item.claimedBy.map(memberIDs.contains) ?? true else { throw AccountError.invalidResponse }
            try Self.validateSources(item.componentSources, components: components)
        }
        try Self.validateRetainedRuns(rawRuns, household: household, memberIDs: memberIDs, components: components, itemIDs: &itemIDs)
    }

    public func claimOwner(for item: ShoppingItem) -> HouseholdMember? {
        members.first { $0.id == item.claimedBy }
    }

    public func inBasket(_ item: ShoppingItem, memberID: UUID) -> Bool {
        item.pickedUp && item.claimedBy == memberID
    }

    public func canEdit(_ item: ShoppingItem, memberID: UUID) -> Bool {
        canAct(on: item, memberID: memberID) && !item.pickedUp
            && (item.claimedBy == nil || item.claimedBy == memberID)
    }

    public func canClaim(_ item: ShoppingItem, claim: Bool, memberID: UUID) -> Bool {
        canAct(on: item, memberID: memberID) && (claim ? item.claimedBy == nil : item.claimedBy != nil)
    }

    public func canPick(_ item: ShoppingItem, pickedUp: Bool, memberID: UUID) -> Bool {
        canAct(on: item, memberID: memberID) && item.pickedUp != pickedUp
            && (item.claimedBy == nil || item.claimedBy == memberID)
    }

    private func canAct(on item: ShoppingItem, memberID: UUID) -> Bool {
        items.contains(item) && members.contains { $0.id == memberID && !$0.inactive }
    }

    private static func validateSources(
        _ sources: [ShoppingComponentSource]?, components: [String: HouseholdComponent]
    ) throws {
        var sourceIDs = Set<String>()
        for source in sources ?? [] {
            guard components[source.componentID]?.roomID == source.roomID,
                  sourceIDs.insert("\(source.componentID):\(source.supplyID)").inserted else {
                throw AccountError.invalidResponse
            }
        }
    }

    private static func validateRetainedRuns(
        _ runs: [JSONValue], household: HouseholdSnapshot, memberIDs: Set<UUID>,
        components: [String: HouseholdComponent], itemIDs: inout Set<UUID>
    ) throws {
        var expenseByRun: [UUID: UUID] = [:]
        var receiptIDs = Set<UUID>()
        for value in runs {
            let fields = try HouseholdFields(value)
            let id = try fields.uuid("id")
            let expenseID = try fields.uuid("expenseId")
            _ = try fields.text("name", length: 1...100)
            let completedBy = try fields.uuid("completedBy")
            _ = try fields.timestamp("completedAt")
            let archived = try fields.array("items")
            guard expenseByRun.updateValue(expenseID, forKey: id) == nil, receiptIDs.insert(expenseID).inserted,
                  memberIDs.contains(completedBy), (1...itemLimit).contains(archived.count) else {
                throw AccountError.invalidResponse
            }
            for value in archived {
                let item = try ShoppingItemSnapshot(value)
                guard itemIDs.insert(item.id).inserted, memberIDs.contains(item.createdBy) else {
                    throw AccountError.invalidResponse
                }
                try validateSources(item.componentSources, components: components)
            }
        }
        for expense in try HouseholdFields(household.value).array("expenses") {
            if let rawID = expense["id"]?.stringValue, let expenseID = HouseholdValidation.uuid(rawID),
               receiptIDs.contains(expenseID) {
                guard expense["shoppingRunId"] != nil else { throw AccountError.invalidResponse }
            }
            guard expense["shoppingRunId"] != nil else { continue }
            let fields = try HouseholdFields(expense)
            let runID = try fields.uuid("shoppingRunId")
            let expenseID = try fields.uuid("id")
            guard expenseByRun[runID] == expenseID, expense["bill"] == nil,
                  memberIDs.contains(try fields.uuid("paidBy")) else { throw AccountError.invalidResponse }
            let participants = try fields.array("participants").map { value in
                guard let raw = value.stringValue, let id = HouseholdValidation.uuid(raw), memberIDs.contains(id) else {
                    throw AccountError.invalidResponse
                }
                return id
            }
            guard (1...12).contains(participants.count), Set(participants).count == participants.count else {
                throw AccountError.invalidResponse
            }
        }
    }
}
