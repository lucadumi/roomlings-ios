import Foundation
import RoomlingsCore

/// Formats whole cents for display. Amounts stay integral; `Decimal` only scales them for
/// presentation, so no amount is ever routed through a binary floating point type.
enum Money {
    static func text(_ cents: Int64, currency: HouseholdCurrency) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.currency(code: currency.rawValue).precision(.fractionLength(2)))
    }

    /// The editable decimal form of a stored amount, for prefilling an amount field.
    static func field(_ cents: Int64) -> String {
        "\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
}
