import Foundation

/// One notification, derived from the saved household exactly as `inboxItems` in the web project's
/// `shared/inbox.ts` derives it, so the inbox never disagrees with the ledger or chores.
public struct InboxItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case chore, expense, bill, settlement }
    /// The web opens a receipt month or the repayments page; the native receipt book lists every
    /// month, so receipts and repayments open at their own row.
    public enum Target: Sendable, Equatable {
        case chore(UUID)
        case receipt(UUID)
        case bills(month: String)
        case repayment(UUID)
    }

    public let id: String
    public let kind: Kind
    /// An ISO timestamp, compared as text as the web compares it.
    public let at: String
    public let title: String
    public let detail: String
    public let amount: Int64?
    public let target: Target
}

/// Each roommate's private read state, kept by the server outside the household.
public struct InboxReadState: Sendable, Equatable, Decodable {
    public static let readLimit = 200
    public let readThrough: String?
    public let readIds: [String]

    public init(readThrough: String?, readIds: [String]) {
        self.readThrough = readThrough
        self.readIds = readIds
    }

    public init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        guard Set(fields.object.keys) == ["readThrough", "readIds"] else { throw AccountError.invalidResponse }
        if case .null = fields.object["readThrough"] {
            readThrough = nil
        } else {
            readThrough = try fields.timestamp("readThrough")
        }
        readIds = try fields.array("readIds").map { value in
            guard let id = value.stringValue, InboxRead.validID(id) else { throw AccountError.invalidResponse }
            return id
        }
        guard readIds.count <= Self.readLimit else { throw AccountError.invalidResponse }
    }

    public func isUnread(_ item: InboxItem) -> Bool {
        !(readThrough.map { item.at <= $0 } ?? false) && !readIds.contains(item.id)
    }

    /// Mirrors `readAll`: the cursor moves to the newest item, so later entries stay unread.
    public func readingAll(_ items: [InboxItem]) -> InboxRead? {
        guard let newest = items.map(\.at).max(), readThrough.map({ $0 < newest }) ?? true else { return nil }
        return InboxRead(through: newest, ids: nil)
    }

    /// Mirrors `mergeInboxRead`, for the optimistic state shown while a save is in flight.
    public func merging(_ read: InboxRead) -> InboxReadState {
        let through = read.through.flatMap { through in readThrough.map { through > $0 } ?? true ? through : nil } ?? readThrough
        var ids = readIds
        for id in read.ids ?? [] where !ids.contains(id) { ids.append(id) }
        return InboxReadState(readThrough: through, readIds: Array(ids.suffix(Self.readLimit)))
    }
}

public struct InboxRead: Sendable, Equatable, Encodable {
    public let through: String?
    public let ids: [String]?

    public init(through: String?, ids: [String]?) {
        self.through = through
        self.ids = ids
    }

    static func validID(_ id: String) -> Bool {
        id.count <= 120 && id.range(of: #"^(chore|expense|settlement):[0-9a-f-]+(:\d{4}-\d{2}-\d{2})?$"#, options: .regularExpression) != nil
    }
}

public enum HouseholdInbox {
    public static let itemLimit = 50
    public static let windowDays = 30

    /// - Parameter roomNames: The shared room names by room ID.
    public static func items(
        chores: HouseholdChores, ledger: HouseholdLedger, bills: HouseholdBills?, memberID: UUID,
        today: String, now: Date = Date(), roomNames: [String: String]
    ) -> [InboxItem] {
        let name = { (id: UUID) in ledger.member(id)?.name ?? "A former roommate" }
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var items: [InboxItem] = []
        for chore in chores.items {
            guard let status = try? chore.status(on: today), status == .due || status == .overdue, let dueDate = chore.dueDate,
                  !chores.isPaused(chore), chores.assignee(for: chore)?.id == memberID else { continue }
            let late = days(from: dueDate, to: today)
            let place = [chore.roomID.map { roomNames[$0] ?? $0 } ?? "Whole home", chore.componentName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            items.append(InboxItem(
                id: "chore:\(chore.id.uuidString.lowercased()):\(dueDate)", kind: .chore, at: "\(dueDate)T00:00:00.000Z",
                title: late > 0 ? "\(chore.title) is \(late) \(late == 1 ? "day" : "days") overdue" : "\(chore.title) is due today",
                detail: "\(place); your turn", amount: nil, target: .chore(chore.id)
            ))
        }
        for expense in ledger.expenses {
            guard expense.paidBy != memberID, expense.participants.contains(memberID),
                  let created = timestamp(expense.createdAt), created >= since else { continue }
            let bill = expense.bill.flatMap { reference in bills?.bills.first { $0.id == reference.billId } }
            let count = expense.participants.count
            items.append(InboxItem(
                id: "expense:\(expense.id.uuidString.lowercased())", kind: expense.bill == nil ? .expense : .bill,
                at: expense.createdAt, title: "\(name(expense.paidBy)) paid \(bill?.latestRevision.name ?? expense.description)",
                detail: "Split \(count) \(count == 1 ? "way" : "ways")", amount: expense.amount,
                target: expense.bill.map { .bills(month: $0.month) } ?? .receipt(expense.id)
            ))
        }
        for settlement in ledger.settlements {
            guard settlement.to == memberID, let created = timestamp(settlement.createdAt), created >= since else { continue }
            items.append(InboxItem(
                id: "settlement:\(settlement.id.uuidString.lowercased())", kind: .settlement, at: settlement.createdAt,
                title: "\(name(settlement.from)) paid you back", detail: "Repayment", amount: settlement.amount,
                target: .repayment(settlement.id)
            ))
        }
        // Turns you owe come first, most overdue at the top; money follows, newest first.
        let rank = { (item: InboxItem) in item.kind == .chore ? 0 : 1 }
        return Array(items.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.at != b.at { return rank(a) == 0 ? a.at < b.at : a.at > b.at }
            return a.id < b.id
        }.prefix(itemLimit))
    }

    private static func days(from: String, to: String) -> Int {
        guard let start = timestamp("\(from)T00:00:00Z"), let end = timestamp("\(to)T00:00:00Z") else { return 0 }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    public static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
