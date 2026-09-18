import Foundation

public enum ExpenseCategory: String, Sendable, Equatable, CaseIterable, Identifiable {
    case produce, dairy, pantry, drinks, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .produce: "Produce"
        case .dairy: "Dairy"
        case .pantry: "Pantry"
        case .drinks: "Drinks"
        case .other: "Other"
        }
    }
}

public struct ExpenseDraft: Sendable, Equatable {
    /// The server rejects anything outside this range, in whole cents.
    public static let amountRange: ClosedRange<Int64> = 1...100_000_000
    /// `participantsSchema` caps a split at the active member limit.
    public static let participantLimit = 12

    public let description: String
    public let amount: Int64
    public let paidBy: UUID
    public let participants: [UUID]
    public let category: ExpenseCategory
    public let date: String

    public init(
        description: String, amount: Int64, paidBy: UUID, participants: [UUID],
        category: ExpenseCategory = .other, date: String
    ) throws {
        guard let description = HouseholdValidation.text(description, length: 1...100) else {
            throw AccountError.invalidInput(.expenseDescription)
        }
        guard Self.amountRange.contains(amount) else { throw AccountError.invalidInput(.amount) }
        guard HouseholdValidation.uuid(paidBy) else { throw AccountError.invalidInput(.paidBy) }
        guard (1...Self.participantLimit).contains(participants.count),
              Set(participants).count == participants.count,
              participants.allSatisfy(HouseholdValidation.uuid) else {
            throw AccountError.invalidInput(.participants)
        }
        guard ChoreValidation.date(date) else { throw AccountError.invalidInput(.date) }
        self.description = description
        self.amount = amount
        self.paidBy = paidBy
        self.participants = participants
        self.category = category
        self.date = date
    }

    var requestFields: [String: JSONValue] {
        [
            "description": .string(description),
            "amount": .integer(amount),
            "paidBy": .string(paidBy.uuidString.lowercased()),
            "participants": .array(participants.map { .string($0.uuidString.lowercased()) }),
            "category": .string(category.rawValue),
            "date": .string(date),
        ]
    }

    /// Mirrors `splitAmount` in the web project's `shared/domain.ts`. The server stays
    /// authoritative; this only previews the same whole-cent division before saving.
    public var shares: [UUID: Int64] {
        let ordered = participants.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let count = Int64(ordered.count)
        let base = amount / count
        let remainder = amount % count
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, member in
            (member, base + (Int64(index) < remainder ? 1 : 0))
        })
    }
}

public struct HouseholdExpense: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let description: String
    public let amount: Int64
    public let paidBy: UUID
    public let participants: [UUID]
    public let category: ExpenseCategory
    public let date: String
    public let createdAt: String
    public let shoppingRunID: UUID?
    /// Bill payments are recorded by the web app and cannot be edited or removed here.
    public let isBillPayment: Bool

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.uuid("id")
        description = try fields.text("description", length: 1...100)
        amount = try fields.integer("amount", range: ExpenseDraft.amountRange)
        paidBy = try fields.uuid("paidBy")
        participants = try fields.array("participants").map { value in
            guard let raw = value.stringValue, let id = HouseholdValidation.uuid(raw) else {
                throw AccountError.invalidResponse
            }
            return id
        }
        guard (1...ExpenseDraft.participantLimit).contains(participants.count),
              Set(participants).count == participants.count else { throw AccountError.invalidResponse }
        guard let category = ExpenseCategory(rawValue: try fields.string("category")) else {
            throw AccountError.invalidResponse
        }
        self.category = category
        date = try fields.string("date")
        guard ChoreValidation.date(date) else { throw AccountError.invalidResponse }
        createdAt = try fields.timestamp("createdAt")
        shoppingRunID = fields.object["shoppingRunId"] == nil ? nil : try fields.uuid("shoppingRunId")
        isBillPayment = fields.object["bill"] != nil
    }

    /// The same whole-cent division the server applies when it computes balances.
    public var shares: [UUID: Int64] {
        let ordered = participants.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let count = Int64(ordered.count)
        let base = amount / count
        let remainder = amount % count
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, member in
            (member, base + (Int64(index) < remainder ? 1 : 0))
        })
    }
}

/// A validated native projection of the shared ledger. The server stays authoritative for
/// balances; this only reads back what was recorded.
public struct HouseholdLedger: Sendable, Equatable {
    public static let expenseLimit = 20_000

    public let expenses: [HouseholdExpense]
    public let members: [HouseholdMember]
    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    /// Active shopping item identifiers, in list order, so a checkout can prove exactly which
    /// items left the shared list.
    let shoppingItemIDs: [UUID]
    let runIDs: Set<UUID>
    let householdVersion: Int64

    public init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        let memberIDs = Set(members.map(\.id))
        let fields = try HouseholdFields(household.value)
        let rawExpenses = try fields.array("expenses")
        guard rawExpenses.count <= Self.expenseLimit else { throw AccountError.invalidResponse }
        expenses = try rawExpenses.map(HouseholdExpense.init)
        var expenseIDs = Set<UUID>()
        for expense in expenses {
            guard expenseIDs.insert(expense.id).inserted, memberIDs.contains(expense.paidBy),
                  expense.participants.allSatisfy(memberIDs.contains) else {
                throw AccountError.invalidResponse
            }
        }
        if let shopping = household.value["shopping"] {
            let shoppingFields = try HouseholdFields(shopping)
            shoppingItemIDs = try shoppingFields.array("items").map { value in
                try HouseholdFields(value).uuid("id")
            }
            runIDs = Set(try shoppingFields.array("runs").map { value in
                try HouseholdFields(value).uuid("id")
            })
        } else {
            shoppingItemIDs = []
            runIDs = []
        }
        guard Set(shoppingItemIDs).count == shoppingItemIDs.count else { throw AccountError.invalidResponse }
    }

    public func member(_ id: UUID) -> HouseholdMember? { members.first { $0.id == id } }

    /// Bill payments and shopping receipts are owned by their originating flow, so only a
    /// plain expense can be removed from here.
    public func canRemove(_ expense: HouseholdExpense, memberID: UUID) -> Bool {
        expenses.contains(expense) && !expense.isBillPayment && expense.shoppingRunID == nil
            && members.contains { $0.id == memberID && !$0.inactive }
    }
}
