import Foundation

/// The web header's house pot: the monthly budget less this month's grocery spending, as
/// `monthlyGroceries` in the web's shared/domain.ts counts it. Bill payments are left out and
/// the month follows the household's billing time zone.
public struct HousePot: Sendable, Equatable {
    public let budget: Int64
    public let spent: Int64
    public let currency: HouseholdCurrency

    public var remaining: Int64 { budget - spent }

    public init(household: HouseholdSnapshot, now: Date = Date()) throws {
        guard let budget = household.value["budget"]?.integerValue else { throw AccountError.invalidResponse }
        let ledger = try HouseholdLedger(household: household)
        let zone = try HouseholdTimeZone(identifier: household.value["billingTimeZone"]?.stringValue ?? "UTC")
        let month = Self.month(of: now, in: zone)
        self.budget = budget
        currency = household.currency
        spent = ledger.expenses
            .filter { $0.bill == nil && $0.date.hasPrefix("\(month)-") }
            .reduce(0) { $0 + $1.amount }
    }

    static func month(of date: Date, in zone: HouseholdTimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        switch zone {
        case .named(let timeZone): calendar.timeZone = timeZone
        case .fixedOffset(let seconds): calendar.timeZone = TimeZone(secondsFromGMT: seconds) ?? .gmt
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
