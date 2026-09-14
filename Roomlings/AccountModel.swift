import CryptoKit
import Foundation
import Observation
import RoomlingsCore

@MainActor @Observable
final class AccountModel {
    private(set) var state: AccountState?
    private(set) var busy = false
    private(set) var restored = false
    private(set) var room = RoomVisualState.preview
    private(set) var roomFailure: String?
    var message: String?
    var notice: String?
    let setupError: String?

    private let client: AccountSession?
    private var deletionBlocked = false

    var signedIn: Bool { state?.isSignedIn == true }
    var deletionPending: Bool { deletionBlocked || state?.deletionPending == true }
    var householdName: String? { deletionPending ? nil : state?.session?.household.name }
    var canUseAccount: Bool { signedIn && !deletionPending }

    init(client: AccountSession) {
        self.client = client
        setupError = nil
    }

    private init(setupError: String) {
        client = nil
        self.setupError = setupError
        message = setupError
    }

    static func live() -> AccountModel {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.roomlings.app"
        var origin = Bundle.main.object(forInfoDictionaryKey: "RoomlingsAPIOrigin") as? String ?? ""
        var service = "\(bundleID).account"
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["ROOMLINGS_API_ORIGIN"] { origin = configured }
        if let isolated = environment["ROOMLINGS_KEYCHAIN_SERVICE"] { service = isolated }
        #endif
        do {
            let configuration = try APIConfiguration(origin: origin)
            let originKey = SHA256.hash(data: Data(configuration.origin.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let store = try KeychainSessionTokenStore(service: "\(service).\(originKey)")
            return AccountModel(client: AccountSession(configuration: configuration, tokenStore: store))
        } catch {
            return AccountModel(setupError: "Account access is not configured. Set the Roomlings API origin in Xcode and rebuild the app.")
        }
    }

    func start() async {
        guard !restored else { return }
        restored = true
        _ = await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        await perform(.refresh) { try await $0.restore() }
    }

    func sendCode(email: String) async -> Bool {
        guard let client, begin() else { return false }
        defer { busy = false }
        do {
            try await client.sendEmailCode(email: email)
            notice = "Check your email for a sign-in code."
            return true
        } catch {
            await failed(error, action: .sendCode, client: client)
            return false
        }
    }

    func verify(email: String, code: String, name: String, label: String) async -> Bool {
        await perform(.verify) {
            try await $0.verifyEmailCode(email: email, code: code, name: name, deviceLabel: label)
        }
    }

    func recover(email: String, code: String, label: String) async -> Bool {
        await perform(.recover) {
            try await $0.recover(email: email, recoveryCode: code, deviceLabel: label)
        }
    }

    func create(name: String, memberName: String, currency: HouseholdCurrency, budget: Int64, requestID: UUID) async -> Bool {
        await perform(.create) {
            try await $0.createHousehold(name: name, memberName: memberName, currency: currency, budgetCents: budget, requestID: requestID)
        }
    }

    func join(code: String, memberName: String) async -> Bool {
        await perform(.join) { try await $0.acceptInvitation(code: code, memberName: memberName) }
    }

    func select(id: UUID) async -> Bool {
        await perform(.select) { try await $0.selectHousehold(id: id) }
    }

    func signOut() async -> Bool {
        await perform(.logout) { try await $0.logout() }
    }

    func clearFeedback() {
        message = nil
        notice = nil
    }

    private func begin() -> Bool {
        guard !busy else { return false }
        if let setupError {
            message = setupError
            return false
        }
        busy = true
        clearFeedback()
        return true
    }

    private func perform(_ action: Action, operation: @Sendable (AccountSession) async throws -> AccountState) async -> Bool {
        guard let client, begin() else { return false }
        defer { busy = false }
        do {
            let next = try await operation(client)
            deletionBlocked = next.deletionPending
            return publish(next)
        } catch {
            await failed(error, action: action, client: client)
            return false
        }
    }

    private func publish(_ next: AccountState?) -> Bool {
        state = next
        roomFailure = nil
        guard !deletionPending, let household = next?.session?.household else {
            room = .preview
            return true
        }
        do {
            room = try RoomVisualState(household: household)
            return true
        } catch {
            room = .preview
            roomFailure = "Your household is saved, but its room data could not be displayed. Refresh your account."
            message = roomFailure
            return false
        }
    }

    private func failed(_ error: Error, action: Action, client: AccountSession) async {
        if case AccountError.server(_, .some(.accountDeletionPending)) = error {
            deletionBlocked = true
        }
        let latest = await client.state
        if latest?.isSignedIn != true { deletionBlocked = false }
        _ = publish(latest)
        message = Self.message(for: error, action: action)
    }

    private enum Action {
        case refresh, sendCode, verify, recover, create, join, select, logout
    }

    private static func message(for error: Error, action: Action) -> String {
        if error is CancellationError { return "The request stopped. Refresh your account before repeating it." }
        if error is KeychainError || (error as? AccountError) == .credentialStorage {
            return "Saved access could not be updated securely. Unlock the device and try again."
        }
        guard let error = error as? AccountError else { return "The account action could not be completed. Try again." }
        switch error {
        case .network:
            return "Could not reach Roomlings. Your saved access is unchanged. Try again."
        case .server(let status, let code):
            if code == .accountDeletionPending { return "Account deletion is pending. Finish it on the web, or sign out here." }
            if code == .authNotConfigured { return "Account access is not configured on this server." }
            if code == .authProviderUnavailable { return "Email sign-in is unavailable right now. Try again or use an unused recovery code." }
            if code == .accountSessionRequired { return "Your session has expired. Sign in again." }
            if code == .reauthenticationRequired { return "Sign in again before continuing this action." }
            if status == 429 { return "Too many attempts. Wait a few minutes before trying again." }
            if status >= 500 { return "Roomlings is temporarily unavailable. Your saved access is unchanged." }
            if action == .join {
                return status == 400 ? "Check the invitation and your name in this household."
                    : "That invitation cannot be used. Ask the owner for a current invitation link."
            }
            if status == 401 {
                return action == .recover ? "That recovery code is invalid or already used. Try another unused code."
                    : "That email code is invalid or expired. Request a new code."
            }
            if status == 403 { return "You no longer have access to that household. Refresh your account." }
            if status == 409 { return "The account changed elsewhere. Refresh it before trying again." }
            return "Check the details and try again."
        case .invalidInput:
            return "Check the details. Names must be 1 to 50 characters, and codes must be complete."
        case .operationInProgress:
            return "Another account action is still running."
        default:
            return "The server response could not be used. Your saved access is unchanged."
        }
    }
}
