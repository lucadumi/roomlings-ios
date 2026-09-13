import Foundation

public enum AccountInputField: String, Sendable {
    case email, emailCode, name, deviceLabel, recoveryCode
    case memberName, budgetCents, invitationCode
}

public enum AccountServerCode: String, Sendable, Codable {
    case accountSessionRequired = "ACCOUNT_SESSION_REQUIRED"
    case reauthenticationRequired = "REAUTHENTICATION_REQUIRED"
    case accountDeletionPending = "ACCOUNT_DELETION_PENDING"
    case accountCreationConflict = "ACCOUNT_CREATION_CONFLICT"
    case authNotConfigured = "AUTH_NOT_CONFIGURED"
    case authProviderUnavailable = "AUTH_PROVIDER_UNAVAILABLE"
    case clientUnsupported = "CLIENT_UNSUPPORTED"
    case nativeClientRequired = "NATIVE_CLIENT_REQUIRED"
}

/// Server text, response bodies, request URLs and underlying errors are deliberately not retained.
public enum AccountError: Error, Sendable, Equatable, LocalizedError {
    case invalidOrigin
    case invalidTimeout
    case invalidInput(AccountInputField)
    case invalidResponse
    case untrustedResponse
    case redirectRejected
    case network(code: Int?)
    case server(status: Int, code: AccountServerCode?)
    case operationInProgress
    case credentialStorage

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin:
            "Use an HTTPS API origin, or HTTP on localhost, 127.0.0.1 or ::1."
        case .invalidTimeout:
            "The API timeout must be positive and finite."
        case .invalidInput(let field):
            "Check the \(field.rawValue) field."
        case .invalidResponse:
            "The server returned an invalid account response."
        case .untrustedResponse:
            "The account response came from a different origin."
        case .redirectRejected:
            "Account API redirects are not permitted."
        case .network:
            "The account request could not be completed."
        case .server(let status, let code):
            "The account request failed (HTTP \(status)\(code.map { ", \($0.rawValue)" } ?? ""))."
        case .operationInProgress:
            "Another account operation is still in progress."
        case .credentialStorage:
            "The account credential could not be read or saved securely."
        }
    }
}

enum AccountValidation {
    static func name(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...50).contains(normalized.utf16.count) ? normalized : nil
    }

    static func email(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?!\.)(?!.*\.\.)[a-z0-9_'+.\-]*[a-z0-9_+\-]@(?:[a-z0-9][a-z0-9\-]*\.)+[a-z]{2,}$"#
        return normalized.utf16.count <= 254 && matches(normalized, pattern) ? normalized : nil
    }

    static func timestamp(_ value: String) -> Bool {
        guard matches(value, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#) else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return false }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).prefix(19) == value.prefix(19)
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }
}
