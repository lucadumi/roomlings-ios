import Foundation

/// The complete shared ledger as the web receipt book exports it, row for row, so a spreadsheet
/// made on either platform matches. Mirrors `exportLedger` in the web project's `src/App.tsx`.
public enum LedgerExport {
    public static let fileName = "roomlings-ledger.csv"
    static let header = ["Type", "Date", "Description", "Amount", "Currency", "Paid by / From", "Split with / To",
                         "Category", "Billing month", "Shopping items"]

    /// - Parameter roomNames: The shared room names by room ID, for restocked items' sources.
    public static func csv(household: HouseholdSnapshot, roomNames: [String: String]) throws -> String {
        let ledger = try HouseholdLedger(household: household)
        guard let currency = household.value["currency"]?.stringValue else { throw AccountError.invalidResponse }
        let runs = try purchasedItems(household)
        let name = { (id: UUID) in ledger.member(id)?.name ?? "Unknown roommate" }
        var rows = [header]
        for expense in ledger.expenses {
            let items = expense.shoppingRunID.flatMap { runs[$0] }?.map { item in
                var text = "\(item.quantity) \(item.name)"
                if !item.notes.isEmpty { text += " (\(item.notes))" }
                if let sources = item.componentSources, !sources.isEmpty {
                    text += " [" + sources.map { "\(roomNames[$0.roomID] ?? $0.roomID): \($0.componentName)" }
                        .joined(separator: ", ") + "]"
                }
                return text
            }.joined(separator: "; ") ?? ""
            rows.append([
                expense.bill == nil ? "Expense" : "Bill", expense.date, expense.description, amount(expense.amount),
                currency, name(expense.paidBy), expense.participants.map(name).joined(separator: "; "),
                expense.bill == nil ? expense.category.label : "Monthly bill", expense.bill?.month ?? "", items,
            ])
        }
        for settlement in ledger.settlements {
            rows.append([
                "Repayment", String(settlement.createdAt.prefix(10)), "Recorded repayment", amount(settlement.amount),
                currency, name(settlement.from), name(settlement.to), "", "", "",
            ])
        }
        return "\u{FEFF}" + rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
    }

    /// Mirrors `escapeCsv` in `shared/domain.ts`: spreadsheet formulas are neutralised and every
    /// field is quoted.
    static func escape(_ value: String) -> String {
        let risky = value.unicodeScalars.first.map { "=+-@\t\r\n".unicodeScalars.contains($0) } ?? false
        let safe = risky ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Whole cents with two decimals, without converting through floating point.
    static func amount(_ cents: Int64) -> String {
        let remainder = cents.magnitude % 100
        return "\(cents < 0 ? "-" : "")\(cents.magnitude / 100).\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private static func purchasedItems(_ household: HouseholdSnapshot) throws -> [UUID: [ShoppingItemSnapshot]] {
        guard let shopping = household.value["shopping"] else { return [:] }
        var runs: [UUID: [ShoppingItemSnapshot]] = [:]
        for value in try HouseholdFields(shopping).array("runs") {
            let fields = try HouseholdFields(value)
            runs[try fields.uuid("id")] = try fields.array("items").map(ShoppingItemSnapshot.init)
        }
        return runs
    }
}
