import Foundation
import JavaScriptCore

public enum HouseholdTimeZone: Sendable, Equatable {
    case named(TimeZone)
    case fixedOffset(seconds: Int)

    public init(identifier: String) throws {
        guard (1...100).contains(identifier.utf16.count) else { throw AccountError.invalidResponse }
        if identifier.hasPrefix("+") || identifier.hasPrefix("-") {
            guard AccountValidation.matches(identifier, #"^[+-](?:[01][0-9]|2[0-3])(?::?[0-5][0-9])?$"#) else {
                throw AccountError.invalidResponse
            }
            let digits = identifier.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)),
                  let minutes = Int(digits.count == 2 ? "00" : String(digits.suffix(2))) else {
                throw AccountError.invalidResponse
            }
            self = .fixedOffset(seconds: (identifier.hasPrefix("-") ? -1 : 1) * (hours * 60 + minutes) * 60)
            return
        }
        if let zone = TimeZone(identifier: identifier) {
            self = .named(zone)
            return
        }
        // Intl accepts case-insensitive IANA aliases that Foundation cannot enumerate.
        // Only this identifier enters the isolated context, never account data or credentials.
        guard let context = JSContext(),
              let normalize = context.evaluateScript(
                "(identifier) => new Intl.DateTimeFormat('en', { timeZone: identifier }).resolvedOptions().timeZone"
              ),
              let value = normalize.call(withArguments: [identifier]),
              context.exception == nil, value.isString,
              let canonical = value.toString(), let zone = TimeZone(identifier: canonical) else {
            throw AccountError.invalidResponse
        }
        self = .named(zone)
    }
}
