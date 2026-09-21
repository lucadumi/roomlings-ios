import Foundation

public enum AnalyticsEventKind: String, Sendable, CaseIterable, Encodable {
    case appOpened = "app_opened"
    case notificationOpened = "notification_opened"
    case inviteShared = "invite_shared"
    case inviteAccepted = "invite_accepted"
}

public struct AnalyticsEvent: Sendable, Equatable, Encodable {
    public let kind: AnalyticsEventKind
    public let occurredAt: String
    public let localDate: String

    public init(kind: AnalyticsEventKind, at date: Date, timeZone: TimeZone = .current) throws {
        guard date.timeIntervalSince1970.isFinite,
              (-62_135_596_800..<253_402_300_800).contains(date.timeIntervalSince1970) else {
            throw AccountError.invalidInput(.date)
        }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let occurredAt = timestamp.string(from: date)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let localDate = day.string(from: date)
        guard AccountValidation.timestamp(occurredAt),
              AccountValidation.matches(localDate, #"^\d{4}-\d{2}-\d{2}$"#) else {
            throw AccountError.invalidInput(.date)
        }
        self.kind = kind
        self.occurredAt = occurredAt
        self.localDate = localDate
    }
}

/// Captured when an action occurs, never serialized into the event body.
public struct AnalyticsContext: Sendable, Hashable {
    public let accountID: UUID
    public let deviceID: UUID
    public let householdID: UUID
    public let memberID: UUID

    public init(state: AccountState) throws {
        guard let account = state.account, !state.deletionPending, let selected = state.session,
              let device = state.devices.first(where: \.current), try !selected.viewer.inactive else {
            throw AccountError.accountStateRequired
        }
        accountID = account.id
        deviceID = device.id
        householdID = selected.household.id
        memberID = selected.memberID
    }
}
