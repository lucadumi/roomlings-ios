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

public struct HouseholdSettlement: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let from: UUID
    public let to: UUID
    public let amount: Int64
    public let createdAt: String

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.uuid("id")
        from = try fields.uuid("from")
        to = try fields.uuid("to")
        amount = try fields.integer("amount", range: 1...HouseholdValidation.maximumInteger)
        createdAt = try fields.timestamp("createdAt")
        guard from != to else { throw AccountError.invalidResponse }
    }
}

/// One member's position in the shared ledger. Positive means the household owes them.
public struct MemberBalance: Sendable, Equatable, Identifiable {
    public let member: HouseholdMember
    public let amount: Int64

    public var id: UUID { member.id }
    public var isOwed: Bool { amount > 0 }
    public var owes: Bool { amount < 0 }
}

/// A proposed repayment. `from` owes and pays `to`, who is owed.
public struct SuggestedTransfer: Sendable, Equatable, Identifiable {
    public let from: UUID
    public let to: UUID
    public let amount: Int64

    public var id: String { "\(from.uuidString)-\(to.uuidString)" }
}

/// A validated native projection of the shared ledger. The server stays authoritative for
/// balances; this only reads back what was recorded.
public struct HouseholdLedger: Sendable, Equatable {
    public static let expenseLimit = 20_000

    public let expenses: [HouseholdExpense]
    public let settlements: [HouseholdSettlement]
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
        let rawSettlements = try fields.array("settlements")
        guard rawSettlements.count <= Self.expenseLimit else { throw AccountError.invalidResponse }
        settlements = try rawSettlements.map(HouseholdSettlement.init)
        var settlementIDs = Set<UUID>()
        for settlement in settlements {
            guard settlementIDs.insert(settlement.id).inserted, memberIDs.contains(settlement.from),
                  memberIDs.contains(settlement.to) else { throw AccountError.invalidResponse }
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

    /// Mirrors `balances` in the web project's `shared/domain.ts`, so the app can never show a
    /// figure the server would contradict. A payer is credited the whole amount, every
    /// participant is debited their whole-cent share, and a repayment credits the member who
    /// paid it back. Positive means the household owes that member.
    public var balances: [MemberBalance] {
        var totals = Dictionary(uniqueKeysWithValues: members.map { ($0.id, Int64(0)) })
        for expense in expenses {
            totals[expense.paidBy, default: 0] += expense.amount
            for (participant, share) in expense.shares {
                totals[participant, default: 0] -= share
            }
        }
        for settlement in settlements {
            totals[settlement.from, default: 0] += settlement.amount
            totals[settlement.to, default: 0] -= settlement.amount
        }
        return members.map { MemberBalance(member: $0, amount: totals[$0.id] ?? 0) }
    }

    /// Mirrors `suggestedTransfers`: the largest debtor pays the largest creditor until one of
    /// them is square, with member ID breaking ties exactly as the shared sort does.
    public var suggestedTransfers: [SuggestedTransfer] {
        let current = balances
        let order: (_ a: (id: UUID, amount: Int64), _ b: (id: UUID, amount: Int64)) -> Bool = { a, b in
            a.amount == b.amount
                ? a.id.uuidString.lowercased() < b.id.uuidString.lowercased()
                : a.amount > b.amount
        }
        var creditors = current.filter { $0.amount > 0 }.map { (id: $0.member.id, amount: $0.amount) }.sorted(by: order)
        var debtors = current.filter { $0.amount < 0 }.map { (id: $0.member.id, amount: -$0.amount) }.sorted(by: order)
        var transfers: [SuggestedTransfer] = []
        var creditor = 0
        var debtor = 0
        while creditor < creditors.count && debtor < debtors.count {
            let amount = min(creditors[creditor].amount, debtors[debtor].amount)
            transfers.append(SuggestedTransfer(from: debtors[debtor].id, to: creditors[creditor].id, amount: amount))
            creditors[creditor].amount -= amount
            debtors[debtor].amount -= amount
            if creditors[creditor].amount == 0 { creditor += 1 }
            if debtors[debtor].amount == 0 { debtor += 1 }
        }
        return transfers
    }

    /// The same guard rails the server applies before it records a repayment, so the app only
    /// offers repayments the ledger will accept.
    public func canSettle(from: UUID, to: UUID, amount: Int64) -> Bool {
        guard from != to, amount > 0 else { return false }
        let current = balances
        guard let owing = current.first(where: { $0.member.id == from })?.amount,
              let owed = current.first(where: { $0.member.id == to })?.amount,
              owing < 0, owed > 0 else { return false }
        return amount <= -owing && amount <= owed
    }

    /// Bill payments and shopping receipts are owned by their originating flow, so only a
    /// plain expense can be removed from here.
    public func canRemove(_ expense: HouseholdExpense, memberID: UUID) -> Bool {
        expenses.contains(expense) && !expense.isBillPayment && expense.shoppingRunID == nil
            && members.contains { $0.id == memberID && !$0.inactive }
    }
}
