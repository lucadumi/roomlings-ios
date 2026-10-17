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

    /// The pause that is still open, if any. Pausing stops future months, not existing dues.
    public var openPause: BillPause? { pauses.first(where: \.isOpen) }

    /// The schedule that future edits start from.
    public var latestRevision: BillRevision { revisions[revisions.count - 1] }

    /// The revision in force for a given month. Earlier revisions are preserved.
    public func revision(for month: String) -> BillRevision? {
        revisions.last(where: { $0.fromMonth <= month })
    }

    /// Whether the bill falls inside a paused window for the given month. A resumed
    /// pause ends at its `untilMonth`, which is scheduled again, matching the shared rules.
    public func isPaused(in month: String) -> Bool {
        pauses.contains { pause in
            guard pause.fromMonth <= month else { return false }
            return pause.untilMonth.map { month < $0 } ?? true
        }
    }

    /// The first month a pause requested in `current` would skip: next month, or the
    /// start month when the bill has not started yet.
    public func pauseMonth(current: String) -> String {
        let next = HouseholdBills.addMonths(current, 1) ?? current
        return startMonth > next ? startMonth : next
    }

    /// Whether the bill is due at all in the given month.
    public func isScheduled(in month: String) -> Bool {
        month >= startMonth && !isPaused(in: month)
    }
}

public struct BillOccurrence: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case paid, overdue, due, upcoming
    }

    public let billID: UUID
    public let month: String
    public let dueDate: String
    public let name: String
    public let amount: Int64
    public let participants: [UUID]
    /// The expense already recorded for this month, if any. A paid month shows the
    /// recorded expense, even if the schedule later changed or paused.
    public let payment: HouseholdExpense?
    public let status: Status
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

    /// The occurrence of a bill in a given month, or `nil` when the bill is unpaid and
    /// paused, before its start month, or otherwise unscheduled for that month.
    /// `today` is the household's billing date, `yyyy-MM-dd`.
    public func occurrence(of bill: Bill, in month: String, today: String) -> BillOccurrence? {
        guard Self.isMonth(month) else { return nil }
        let payment = expenses.first { $0.bill?.billId == bill.id && $0.bill?.month == month }
        return Self.occurrence(of: bill, in: month, today: today, payment: payment)
    }

    /// Every bill due in a month, ordered by due date, then name, like the web panel.
    public func monthlyBills(in month: String, today: String) -> [BillOccurrence] {
        guard Self.isMonth(month) else { return [] }
        let payments = recordedPayments
        return bills.compactMap { bill in
            Self.occurrence(of: bill, in: month, today: today, payment: payments[PaymentKey(bill: bill.id, month: month)])
        }.sorted { left, right in
            if left.dueDate != right.dueDate { return left.dueDate < right.dueDate }
            if left.name != right.name { return left.name < right.name }
            return left.billID.uuidString.lowercased() < right.billID.uuidString.lowercased()
        }
    }

    /// Unpaid, past-due bills in months before `month`, so an overdue bill never
    /// disappears from view when the board shows a later month.
    public func earlierOverdue(before month: String, today: String) -> (count: Int, firstMonth: String?) {
        guard Self.isMonth(month), today.count >= 7 else { return (0, nil) }
        let payments = recordedPayments
        let currentMonth = String(today.prefix(7))
        var count = 0
        var firstMonth: String?
        for bill in bills {
            var candidate = bill.startMonth
            while candidate < month && candidate <= currentMonth {
                if payments[PaymentKey(bill: bill.id, month: candidate)] == nil, bill.isScheduled(in: candidate),
                   let revision = bill.revision(for: candidate),
                   Self.dueDate(candidate, day: revision.dueDay) < today {
                    count += 1
                    if firstMonth.map({ candidate < $0 }) ?? true { firstMonth = candidate }
                }
                guard candidate != currentMonth, let next = Self.addMonths(candidate, 1) else { break }
                candidate = next
            }
        }
        return (count, firstMonth)
    }

    /// The earliest month the board can show: the first bill's start, or the current month.
    public func firstMonth(current: String) -> String {
        bills.map(\.startMonth).reduce(current) { min($0, $1) }
    }

    public static func addMonths(_ month: String, _ offset: Int) -> String? {
        guard isMonth(month) else { return nil }
        let parts = month.split(separator: "-")
        guard let year = Int(parts[0]), let number = Int(parts[1]) else { return nil }
        let index = year * 12 + number - 1 + offset
        let (nextYear, nextMonth) = index.quotientAndRemainder(dividingBy: 12)
        guard (0...9999).contains(nextYear), index >= 0 else { return nil }
        return String(format: "%04d-%02d", nextYear, nextMonth + 1)
    }

    private struct PaymentKey: Hashable {
        let bill: UUID
        let month: String
    }

    private var recordedPayments: [PaymentKey: HouseholdExpense] {
        var payments: [PaymentKey: HouseholdExpense] = [:]
        for expense in expenses {
            if let bill = expense.bill { payments[PaymentKey(bill: bill.billId, month: bill.month)] = expense }
        }
        return payments
    }

    private static func occurrence(of bill: Bill, in month: String, today: String,
                                   payment: HouseholdExpense?) -> BillOccurrence? {
        if let payment, let reference = payment.bill {
            return BillOccurrence(
                billID: bill.id, month: month, dueDate: reference.dueDate,
                name: payment.description, amount: payment.amount, participants: payment.participants,
                payment: payment, status: .paid
            )
        }
        guard month >= bill.startMonth, bill.isScheduled(in: month),
              let revision = bill.revision(for: month) else { return nil }
        let dueDate = Self.dueDate(month, day: revision.dueDay)
        return BillOccurrence(
            billID: bill.id, month: month, dueDate: dueDate,
            name: revision.name, amount: revision.amount, participants: revision.participants,
            payment: nil, status: dueDate < today ? .overdue : dueDate == today ? .due : .upcoming
        )
    }

    private static func isMonth(_ month: String) -> Bool {
        AccountValidation.matches(month, #"^[0-9]{4}-[0-9]{2}$"#) && (1...12).contains(Int(month.suffix(2)) ?? 0)
    }

    static func dueDate(_ month: String, day: Int) -> String {
        "\(month)-\(String(format: "%02d", min(day, daysInMonth(month))))"
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
