import Foundation

/// One month-forward revision of a bill. The server keeps earlier revisions so past
/// months keep their historical name, amount and split.
public struct BillRevision: Sendable, Equatable {
    public let fromMonth: String
    public let name: String
    public let amount: Int64
    public let dueDay: Int
    public let participants: [UUID]

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        fromMonth = try fields.string("fromMonth")
        name = try fields.text("name", length: 1...100)
        amount = try fields.integer("amount", range: 1...100_000_000)
        dueDay = Int(try fields.integer("dueDay", range: 1...31))
        participants = try fields.array("participants").map { value in
            guard let raw = value.stringValue, let id = HouseholdValidation.uuid(raw) else {
                throw AccountError.invalidResponse
            }
            return id
        }
        guard AccountValidation.matches(fromMonth, #"^[0-9]{4}-[0-9]{2}$"#),
              (1...12).contains(Int(fromMonth.suffix(2)) ?? 0),
              (1...ExpenseDraft.participantLimit).contains(participants.count),
              Set(participants).count == participants.count else {
            throw AccountError.invalidResponse
        }
    }
}

/// A paused window. `untilMonth == nil` means the pause is still open.
public struct BillPause: Sendable, Equatable {
    public let fromMonth: String
    public let untilMonth: String?

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        fromMonth = try fields.string("fromMonth")
        untilMonth = try fields.nullableString("untilMonth")
        guard AccountValidation.matches(fromMonth, #"^[0-9]{4}-[0-9]{2}$"#),
              untilMonth.map({ AccountValidation.matches($0, #"^[0-9]{4}-[0-9]{2}$"#) && $0 >= fromMonth }) ?? true else {
            throw AccountError.invalidResponse
        }
    }

    public var isOpen: Bool { untilMonth == nil }
}

public struct Bill: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: String
    public let startMonth: String
    public let pauses: [BillPause]
    public let revisions: [BillRevision]

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.uuid("id")
        createdAt = try fields.timestamp("createdAt")
        startMonth = try fields.string("startMonth")
        guard AccountValidation.matches(startMonth, #"^[0-9]{4}-[0-9]{2}$"#) else {
            throw AccountError.invalidResponse
        }
        let rawPauses = try fields.array("pauses")
        let rawRevisions = try fields.array("revisions")
        guard (1...200).contains(rawRevisions.count), rawPauses.count <= 400 else {
            throw AccountError.invalidResponse
        }
        pauses = try rawPauses.map(BillPause.init)
        revisions = try rawRevisions.map(BillRevision.init)
        let months = revisions.map(\.fromMonth)
        guard months == months.sorted(), Set(months).count == months.count,
              revisions.first?.fromMonth == startMonth else {
            throw AccountError.invalidResponse
        }
        let pauseStarts = pauses.map(\.fromMonth)
        guard pauseStarts == pauseStarts.sorted(), Set(pauseStarts).count == pauseStarts.count else {
            throw AccountError.invalidResponse
        }
    }

    public var isPaused: Bool { pauses.contains(where: \.isOpen) }

    /// The revision in force for a given month. Earlier revisions are preserved.
    public func revision(for month: String) -> BillRevision? {
        revisions.last(where: { $0.fromMonth <= month })
    }

    /// Whether the bill falls inside a paused window for the given month.
    public func isPaused(in month: String) -> Bool {
        pauses.contains { pause in
            guard pause.fromMonth <= month else { return false }
            return pause.untilMonth.map { $0 >= month } ?? true
        }
    }
}

public struct BillOccurrence: Sendable, Equatable {
    public let billID: UUID
    public let month: String
    public let dueDate: String
    public let name: String
    public let amount: Int64
    public let participants: [UUID]
    /// The expense already recorded for this month, if any. Paused and unpaid months have `nil`.
    public let payment: HouseholdExpense?
}

/// A validated native projection of the shared monthly bills. The server stays
/// authoritative for due dates and payment history; this only reads what was recorded.
public struct HouseholdBills: Sendable, Equatable {
    public static let billLimit = 100

    public let householdVersion: Int64
    public let bills: [Bill]
    public let expenses: [HouseholdExpense]
    public let members: [HouseholdMember]
    public let billingTimeZone: String

    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    public init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        let memberIDs = Set(members.map(\.id))
        let fields = try HouseholdFields(household.value)
        billingTimeZone = household.value["billingTimeZone"] == nil ? "UTC" : try fields.string("billingTimeZone")

        if let raw = household.value["bills"] {
            guard let values = raw.arrayValue, values.count <= Self.billLimit else {
                throw AccountError.invalidResponse
            }
            bills = try values.map(Bill.init)
        } else {
            bills = []
        }

        var billIDs = Set<UUID>()
        for bill in bills {
            guard billIDs.insert(bill.id).inserted else { throw AccountError.invalidResponse }
            for revision in bill.revisions where !revision.participants.allSatisfy(memberIDs.contains) {
                throw AccountError.invalidResponse
            }
        }

        let rawExpenses = try fields.array("expenses")
        guard rawExpenses.count <= HouseholdLedger.expenseLimit else { throw AccountError.invalidResponse }
        expenses = try rawExpenses.map(HouseholdExpense.init)
        for expense in expenses {
            if let bill = expense.bill, !billIDs.contains(bill.billId) {
                throw AccountError.invalidResponse
            }
        }
    }

    /// The occurrence of a bill in a given month, or `nil` when the bill is paused,
    /// before its start month, or otherwise unscheduled for that month.
    public func occurrence(of bill: Bill, in month: String) -> BillOccurrence? {
        guard AccountValidation.matches(month, #"^[0-9]{4}-[0-9]{2}$"#),
              month >= bill.startMonth,
              !bill.isPaused(in: month),
              let revision = bill.revision(for: month) else { return nil }
        let day = min(revision.dueDay, Self.daysInMonth(month))
        let dueDate = "\(month)-\(String(format: "%02d", day))"
        let payment = expenses.first { $0.bill?.billId == bill.id && $0.bill?.month == month }
        return BillOccurrence(
            billID: bill.id, month: month, dueDate: dueDate,
            name: revision.name, amount: revision.amount, participants: revision.participants,
            payment: payment
        )
    }

    /// Whether a bill can be paused or resumed from the current state. Server enforces
    /// the same guard: you cannot pause a paused bill or resume an active one.
    public func canPause(_ bill: Bill, _ paused: Bool) -> Bool {
        bill.isPaused != paused
    }

    static func daysInMonth(_ month: String) -> Int {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let mon = Int(parts[1]),
              (1...12).contains(mon) else { return 28 }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mon - 1]
    }
}

extension HouseholdBills: HouseholdProjection {
    // Bills are optional in the household schema, so this projection proves it read a
    // valid household by checking `expenses`, which is always present.
    static let collectionKey = "expenses"
}

public struct BillDraft: Sendable, Equatable {
    public let name: String
    public let amount: Int64
    public let firstDueDate: String
    public let participants: [UUID]
    public let timeZone: String?

    public init(
        name: String, amount: Int64, firstDueDate: String, participants: [UUID], timeZone: String? = nil
    ) throws {
        guard let name = HouseholdValidation.text(name, length: 1...100) else {
            throw AccountError.invalidInput(.billName)
        }
        guard ExpenseDraft.amountRange.contains(amount) else { throw AccountError.invalidInput(.amount) }
        guard ChoreValidation.date(firstDueDate) else { throw AccountError.invalidInput(.date) }
        guard (1...ExpenseDraft.participantLimit).contains(participants.count),
              Set(participants).count == participants.count,
              participants.allSatisfy(HouseholdValidation.uuid) else {
            throw AccountError.invalidInput(.participants)
        }
        if let timeZone { _ = try HouseholdTimeZone(identifier: timeZone) }
        self.name = name
        self.amount = amount
        self.firstDueDate = firstDueDate
        self.participants = participants
        self.timeZone = timeZone
    }

    var requestFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "name": .string(name),
            "amount": .integer(amount),
            "firstDueDate": .string(firstDueDate),
            "participants": .array(participants.map { .string($0.uuidString.lowercased()) }),
        ]
        if let timeZone { fields["timeZone"] = .string(timeZone) }
        return fields
    }
}

public struct BillEditDraft: Sendable, Equatable {
    public let name: String
    public let amount: Int64
    public let dueDay: Int
    public let participants: [UUID]
    /// Optional. When `nil` the server revises from the household's current local month.
    public let fromMonth: String?

    public init(
        name: String, amount: Int64, dueDay: Int, participants: [UUID], fromMonth: String? = nil
    ) throws {
        guard let name = HouseholdValidation.text(name, length: 1...100) else {
            throw AccountError.invalidInput(.billName)
        }
        guard ExpenseDraft.amountRange.contains(amount) else { throw AccountError.invalidInput(.amount) }
        guard (1...31).contains(dueDay) else { throw AccountError.invalidInput(.dueDay) }
        guard (1...ExpenseDraft.participantLimit).contains(participants.count),
              Set(participants).count == participants.count,
              participants.allSatisfy(HouseholdValidation.uuid) else {
            throw AccountError.invalidInput(.participants)
        }
        if let fromMonth, !AccountValidation.matches(fromMonth, #"^[0-9]{4}-[0-9]{2}$"#) {
            throw AccountError.invalidInput(.month)
        }
        self.name = name
        self.amount = amount
        self.dueDay = dueDay
        self.participants = participants
        self.fromMonth = fromMonth
    }

    var requestFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "name": .string(name),
            "amount": .integer(amount),
            "dueDay": .integer(Int64(dueDay)),
            "participants": .array(participants.map { .string($0.uuidString.lowercased()) }),
        ]
        if let fromMonth { fields["fromMonth"] = .string(fromMonth) }
        return fields
    }
}

public struct BillPaymentDraft: Sendable, Equatable {
    public let month: String
    public let amount: Int64
    public let paidBy: UUID
    public let participants: [UUID]
    public let date: String

    public init(month: String, amount: Int64, paidBy: UUID, participants: [UUID], date: String) throws {
        guard AccountValidation.matches(month, #"^[0-9]{4}-[0-9]{2}$"#) else {
            throw AccountError.invalidInput(.month)
        }
        guard ExpenseDraft.amountRange.contains(amount) else { throw AccountError.invalidInput(.amount) }
        guard HouseholdValidation.uuid(paidBy) else { throw AccountError.invalidInput(.paidBy) }
        guard (1...ExpenseDraft.participantLimit).contains(participants.count),
              Set(participants).count == participants.count,
              participants.allSatisfy(HouseholdValidation.uuid) else {
            throw AccountError.invalidInput(.participants)
        }
        guard ChoreValidation.date(date) else { throw AccountError.invalidInput(.date) }
        self.month = month
        self.amount = amount
        self.paidBy = paidBy
        self.participants = participants
        self.date = date
    }

    var requestFields: [String: JSONValue] {
        [
            "month": .string(month),
            "amount": .integer(amount),
            "paidBy": .string(paidBy.uuidString.lowercased()),
            "participants": .array(participants.map { .string($0.uuidString.lowercased()) }),
            "date": .string(date),
        ]
    }
}
