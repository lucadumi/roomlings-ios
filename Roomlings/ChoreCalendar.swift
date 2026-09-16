import Foundation
import RoomlingsCore

struct ChoreCalendar: Sendable {
    let identifier: String
    let timeZone: TimeZone
    let calendar: Calendar
    let minimumDate: Date
    private let fixedOffset: TimeInterval

    init(chores: HouseholdChores) throws {
        identifier = chores.billingTimeZone
        switch chores.timeZone {
        case .named(let zone):
            timeZone = zone
            fixedOffset = 0
        case .fixedOffset(let seconds):
            timeZone = .gmt
            fixedOffset = TimeInterval(seconds)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        guard let minimum = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) else {
            throw AccountError.invalidResponse
        }
        minimumDate = minimum
    }

    func day(_ date: Date = .now) -> String {
        let formatter = Self.formatter("yyyy-MM-dd", timeZone: timeZone)
        return formatter.string(from: pickerDate(date))
    }

    // Intl offsets extend to 23:59, beyond Foundation's fixed-zone limit of 18 hours.
    func pickerDate(_ instant: Date) -> Date {
        instant.addingTimeInterval(fixedOffset)
    }

    func instant(fromPickerDate date: Date) -> Date {
        date.addingTimeInterval(-fixedOffset)
    }

    func completionDay(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = timestamp.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        return day(date)
    }

    static func title(_ day: String, today: String) -> String {
        if day == today { return "Today" }
        let parser = formatter("yyyy-MM-dd", timeZone: .gmt)
        guard let date = parser.date(from: day) else { return day }
        if let current = parser.date(from: today),
           let yesterday = parser.calendar.date(byAdding: .day, value: -1, to: current),
           parser.string(from: yesterday) == day { return "Yesterday" }
        return formatter("d MMM", timeZone: .gmt).string(from: date)
    }

    static func repeats(_ days: Int?) -> String {
        guard let days else { return "One-off" }
        if days == 1 { return "Daily" }
        if days == 7 { return "Weekly" }
        return days.isMultiple(of: 7) ? "Every \(days / 7) weeks" : "Every \(days) days"
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
