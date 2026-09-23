import Foundation
import Observation
import OSLog
import RoomlingsCore
import UIKit
import UserNotifications

private let notificationLog = Logger(subsystem: "com.roomlings.app", category: "Notifications")

enum NotificationPermission: Equatable {
    case notDetermined, allowed, denied
}

@MainActor
protocol NotificationSystem: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func register()
    func unregister()
    func clearDelivered()
    func openSettings() async -> Bool
}

@MainActor
final class SystemNotifications: NotificationSystem {
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default:
            notificationLog.error("The system returned an unsupported notification permission state.")
            return .denied
        }
    }

    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
    func clearDelivered() { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }

    func openSettings() async -> Bool {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return false }
        return await UIApplication.shared.open(url)
    }
}

@MainActor @Observable
final class NativeNotifications {
    struct Pending: Equatable, Identifiable {
        let id = UUID()
        let receivedAt = Date()
        let destination: NotificationDestination
    }

    private struct Registration: Equatable {
        let accountID: UUID
        let installationID: UUID
        let token: APNsDeviceToken
    }

    private(set) var permission = NotificationPermission.notDetermined
    private(set) var settings: HouseholdNotificationSettings?
    private(set) var busy = false
    private(set) var registered = false
    private(set) var waitingForAPNs = false
    private(set) var error: String?
    private(set) var routingError: String?
    private(set) var pending: Pending?
    private(set) var installation: PushInstallation?

    private weak var account: AccountModel?
    private let system: any NotificationSystem
    private let environment: APNsEnvironment?
    private var accountID: UUID?
    private var sessionID: UUID?
    private var householdID: UUID?
    private var token: APNsDeviceToken?
    private var attemptedRegistration: Registration?
    private var removalPending = false
    private var loadedInstallation = false
    private var requestedAPNs = false
    private var resynchronize = false
    private var refreshRequested = false

    var enabledOnDevice: Bool {
        guard let accountID else { return false }
        return installation?.enabled == true && installation?.accountID == accountID
    }

    init(system: any NotificationSystem, environment: APNsEnvironment?) {
        self.system = system
        self.environment = environment
    }

    static func live() -> NativeNotifications {
        let environment: APNsEnvironment?
        switch Bundle.main.object(forInfoDictionaryKey: "RoomlingsAPNsEnvironment") as? String {
        case "development": environment = .sandbox
        case "production": environment = .production
        default: environment = nil
        }
        return NativeNotifications(system: SystemNotifications(), environment: environment)
    }

    func attach(to account: AccountModel) {
        self.account = account
        let nextAccount = account.canUseAccount ? account.state?.account?.id : nil
        let nextSession = account.canUseAccount ? account.state?.devices.first(where: \.current)?.id : nil
        let nextHousehold = account.state?.session?.household.id
        if accountID != nextAccount || sessionID != nextSession {
            if accountID != nil && accountID != nextAccount {
                system.unregister()
                system.clearDelivered()
            }
            accountID = nextAccount
            sessionID = nextSession
            attemptedRegistration = nil
            token = nil
            requestedAPNs = false
            waitingForAPNs = false
            registered = false
            removalPending = false
            settings = nil
        }
        if householdID != nextHousehold {
            householdID = nextHousehold
            settings = nil
        }
        if account.deletionPending || account.accountDeletionConfirmed {
            pending = nil
            routingError = nil
            error = nil
        }
        if account.accountDeletionConfirmed {
            installation = nil
            loadedInstallation = false
        }
        account.notificationFailure = error
    }

    func synchronize() async {
        guard let account, account.restored else { return }
        guard !busy, !account.busy else {
            resynchronize = true
            return
        }
        guard account.canUseAccount else {
            registered = false
            return
        }
        if refreshRequested {
            refreshRequested = false
            await refreshSettings()
            return
        }
        busy = true
        defer { finishWork() }
        do {
            try await loadInstallation()
            permission = await system.permission()
            if removalPending {
                try await removeDevice()
            } else if enabledOnDevice {
                if permission == .denied {
                    try await disableDevice()
                } else if permission == .allowed {
                    try requestAPNs()
                    try await uploadToken()
                }
            }
        } catch {
            report(error)
        }
    }

    func refreshSettings() async {
        guard !Task.isCancelled else {
            notificationLog.debug("Notification settings view closed before its read started.")
            return
        }
        guard let account, account.canUseAccount else {
            setError("Sign in and open your household before using notifications.")
            return
        }
        guard !busy, !account.busy else {
            refreshRequested = true
            return
        }
        guard begin(clearError: false) else { return }
        defer { finishWork() }
        do {
            try await loadInstallation()
            permission = await system.permission()
            try await loadPreferences()
            setError(nil)
        } catch is CancellationError where Task.isCancelled {
            notificationLog.debug("Notification settings read cancelled because its view closed.")
        } catch {
            report(error)
        }
    }

    func savePreferences(_ preferences: NotificationPreferences) async {
        guard let account, let householdID else {
            setError("Open your household before changing notifications.")
            return
        }
        guard begin() else { return }
        defer { finishWork() }
        do {
            let next = try await account.saveNotificationSettings(preferences, householdID: householdID)
            guard self.householdID == next.householdID else { throw AccountError.householdSelectionChanged }
            settings = next
        } catch {
            report(error)
        }
    }

    func enable() async {
        guard let account, let accountID else {
            setError("Sign in before enabling notifications.")
            return
        }
        guard begin() else { return }
        defer { finishWork() }
        do {
            try await loadInstallation()
            try await loadPreferences()
            guard settings?.pushAvailable == true, environment != nil else {
                throw PushFailure.notConfigured
            }
            permission = await system.permission()
            if permission == .notDetermined {
                let allowed = try await system.requestPermission()
                permission = allowed ? .allowed : .denied
            }
            guard permission == .allowed else { throw PushFailure.permissionDenied }
            guard account.canUseAccount, self.accountID == accountID else { throw AccountError.accountStateRequired }
            guard let installation, let store = account.notificationStore else { throw PushFailure.storageUnavailable }
            let enabled = PushInstallation(id: installation.id, enabled: true, accountID: accountID)
            try await store.save(enabled)
            guard account.canUseAccount, self.accountID == accountID else {
                if try await store.read() == enabled { try await store.clear() }
                throw AccountError.accountStateRequired
            }
            self.installation = enabled
            attemptedRegistration = nil
            requestedAPNs = false
            token = nil
            try requestAPNs()
            try await uploadToken()
        } catch {
            if account.canUseAccount, self.accountID == accountID {
                report(error)
            } else {
                notificationLog.error("Notification enable stopped because account access changed.")
            }
        }
    }

    func disable() async {
        guard begin() else { return }
        defer { finishWork() }
        do {
            try await loadInstallation()
            try await disableDevice()
        } catch {
            report(error)
        }
    }

    func retry() async {
        attemptedRegistration = nil
        requestedAPNs = false
        setError(nil)
        await synchronize()
        if error == nil { await refreshSettings() }
    }

    func openSystemSettings() async {
        if !(await system.openSettings()) {
            setError("Notification settings could not be opened. Open Settings and choose Roomlings.")
        }
    }

    func receivedDeviceToken(_ data: Data) {
        waitingForAPNs = false
        do {
            let next = try APNsDeviceToken(data: data)
            if token != next {
                token = next
                registered = false
                attemptedRegistration = nil
            }
            Task { await synchronize() }
        } catch {
            setError("The notification token could not be used. Retry notification registration.")
        }
    }

    func registrationFailed() {
        guard requestedAPNs, enabledOnDevice else { return }
        waitingForAPNs = false
        requestedAPNs = false
        registered = false
        setError("Could not register for notifications. Check your connection and this build's Push Notifications signing, then retry.")
    }

    func receiveNotification(_ data: Data) {
        do {
            pending = Pending(destination: try JSONDecoder().decode(NotificationDestination.self, from: data))
            if routingError != nil, error == routingError { setError(nil) }
            routingError = nil
        } catch {
            rejectNotification()
        }
    }

    func rejectNotification() {
        pending = nil
        routingError = "This notification could not be opened. Open the household from Account instead."
        setError(routingError)
    }

    func finishOpening(_ id: UUID) {
        if pending?.id == id { pending = nil }
    }

    func cancelPending() { pending = nil }

    func canPresent(_ destination: NotificationDestination) -> Bool {
        guard enabledOnDevice, permission == .allowed, let account, account.canUseAccount,
              account.state?.memberships.contains(where: { $0.householdID == destination.householdID }) == true else {
            return false
        }
        if let settings, settings.householdID == destination.householdID {
            switch destination.target {
            case .chores: return settings.preferences.chores
            case .expense, .settlement: return settings.preferences.money
            }
        }
        return true
    }

    private func finishWork() {
        busy = false
        if refreshRequested, account?.busy == false {
            refreshRequested = false
            Task { await refreshSettings() }
        } else if resynchronize, account?.busy == false {
            resynchronize = false
            Task { await synchronize() }
        }
    }

    private func begin(clearError: Bool = true) -> Bool {
        guard !busy, let account, !account.busy, account.canUseAccount else {
            setError("Wait for the current account action, then open your household and retry notifications.")
            return false
        }
        busy = true
        if clearError { setError(nil) }
        return true
    }

    private func loadInstallation() async throws {
        guard !loadedInstallation else { return }
        guard let store = account?.notificationStore else { throw PushFailure.storageUnavailable }
        installation = try await store.read() ?? PushInstallation(id: UUID(), enabled: false)
        loadedInstallation = true
    }

    private func loadPreferences() async throws {
        guard let account, let householdID else { throw AccountError.accountStateRequired }
        let next = try await account.loadNotificationSettings(householdID: householdID)
        guard self.householdID == next.householdID else { throw AccountError.householdSelectionChanged }
        settings = next
    }

    private func requestAPNs() throws {
        guard environment != nil else { throw PushFailure.notConfigured }
        guard !requestedAPNs else { return }
        requestedAPNs = true
        waitingForAPNs = true
        system.register()
    }

    private func uploadToken() async throws {
        guard enabledOnDevice, permission == .allowed, let token, let account, let accountID,
              let installation, let environment else { return }
        let registration = Registration(accountID: accountID, installationID: installation.id, token: token)
        guard attemptedRegistration != registration else { return }
        attemptedRegistration = registration
        try await account.registerPushDevice(installationID: installation.id, token: token, environment: environment)
        guard self.accountID == accountID, enabledOnDevice, self.token == token else { return }
        registered = true
        waitingForAPNs = false
        setError(nil)
    }

    private func disableDevice() async throws {
        guard let installation, let store = account?.notificationStore else { throw PushFailure.storageUnavailable }
        let disabled = PushInstallation(id: installation.id, enabled: false)
        try await store.save(disabled)
        self.installation = disabled
        registered = false
        waitingForAPNs = false
        requestedAPNs = false
        attemptedRegistration = nil
        token = nil
        removalPending = true
        system.unregister()
        system.clearDelivered()
        try await removeDevice()
    }

    private func removeDevice() async throws {
        guard let account, let installation else { throw AccountError.accountStateRequired }
        try await account.unregisterPushDevice(installationID: installation.id)
        removalPending = false
    }

    private func setError(_ message: String?) {
        error = message
        account?.notificationFailure = message
    }

    private func report(_ error: any Error) {
        switch error {
        case PushFailure.notConfigured, AccountError.server(503, .some(.pushNotConfigured)):
            setError("Push notifications are not configured for this build or server yet.")
        case PushFailure.permissionDenied:
            setError("Notifications are off in iOS Settings. You can still change your household preferences here.")
        case PushFailure.storageUnavailable, is KeychainError:
            setError("Notification preferences could not be read or saved securely. Unlock this device and retry.")
        case AccountError.server(_, .some(.accountSessionRequired)), AccountError.accountStateRequired:
            setError("Sign in and open your household before using notifications.")
        case AccountError.householdSelectionChanged, AccountError.server(403, _), AccountError.server(404, _):
            settings = nil
            setError("Your household access changed. Refresh Account before changing notifications.")
        case is CancellationError:
            setError("The notification request stopped. Refresh notifications before retrying.")
        default:
            setError(removalPending
                ? "Notifications stopped on this device, but server removal could not be confirmed. Retry notifications."
                : "The notification change could not be confirmed. Check your connection and refresh notifications.")
        }
    }

    private enum PushFailure: Error {
        case notConfigured, permissionDenied, storageUnavailable
    }
}

@MainActor
final class RoomlingsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let notifications = NativeNotifications.live()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        notifications.receivedDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        notifications.registrationFailed()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        guard let payload = notification.request.content.userInfo["roomlings"],
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let destination = try? JSONDecoder().decode(NotificationDestination.self, from: data) else {
            notificationLog.error("An invalid notification payload was suppressed in the foreground.")
            completionHandler([])
            return
        }
        Task { @MainActor in
            completionHandler(notifications.canPresent(destination) ? [.banner, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let data = response.notification.request.content.userInfo["roomlings"].flatMap {
            try? JSONSerialization.data(withJSONObject: $0)
        }
        Task { @MainActor in
            if let data { notifications.receiveNotification(data) }
            else { notifications.rejectNotification() }
            completionHandler()
        }
    }
}
