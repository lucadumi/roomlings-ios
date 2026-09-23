import XCTest
import RoomlingsCore
@testable import Roomlings

@MainActor
final class NotificationModelTests: XCTestCase {
    private let fixture = InvitationModelFixture()
    private let accountID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    func testLoadingPreferencesDoesNotAskPermissionOrRegisterAnUnconsentedDevice() async throws {
        let setup = try await make([settings()])
        await setup.notifications.synchronize()
        await setup.notifications.refreshSettings()
        XCTAssertEqual(setup.system.requests, 0)
        XCTAssertEqual(setup.system.registrations, 0)
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.notifications.settings?.preferences, NotificationPreferences(chores: true, money: true))
        let saves = await setup.store.saves
        XCTAssertEqual(saves, 0)
    }

    func testOpeningSettingsDuringStartupPermissionRefreshDefersInsteadOfDroppingTheLoad() async throws {
        let setup = try await make([settings()])
        let gate = InvitationModelSignal()
        setup.system.permissionGate = gate
        let startup = Task { await setup.notifications.synchronize() }
        await waitUntil { setup.notifications.busy }
        await setup.notifications.refreshSettings()
        XCTAssertNil(setup.notifications.error)
        await gate.signal()
        await startup.value
        await waitUntil { setup.notifications.settings != nil }
        XCTAssertNil(setup.notifications.error)
        XCTAssertEqual(setup.system.requests, 0)
        XCTAssertEqual(setup.system.registrations, 0)
    }

    func testCancellingTheSettingsReadWhenAccountClosesDoesNotLeaveTheHeaderInError() async throws {
        let setup = try await make([settings(), settings(chores: false)], holdIndex: 1)
        let reading = Task { await setup.notifications.refreshSettings() }
        await setup.transport.started.wait()
        XCTAssertTrue(setup.account.busy)
        reading.cancel()
        await setup.transport.finish.signal()
        await reading.value
        XCTAssertNil(setup.notifications.settings)
        XCTAssertNil(setup.notifications.error)
        XCTAssertNil(setup.account.notificationFailure)
        XCTAssertEqual(setup.account.headerStatus, .loaded)
        XCTAssertFalse(setup.account.busy)
        XCTAssertFalse(setup.notifications.busy)
        await setup.notifications.refreshSettings()
        XCTAssertEqual(setup.notifications.settings?.preferences, NotificationPreferences(chores: false, money: true))
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testAnAlreadyCancelledViewTaskCannotStartOrDeferASettingsRead() async throws {
        let setup = try await make([])
        let start = InvitationModelSignal()
        let reading = Task {
            await start.wait()
            await setup.notifications.refreshSettings()
        }
        reading.cancel()
        await start.signal()
        await reading.value
        await setup.notifications.synchronize()
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(setup.notifications.error)
        XCTAssertNil(setup.account.notificationFailure)
        XCTAssertEqual(setup.account.headerStatus, .loaded)
    }

    func testAnActualSettingsReadFailureStillMakesTheHeaderNeedAttention() async throws {
        let setup = try await make([fixture.failure(503)])
        await setup.notifications.refreshSettings()
        XCTAssertNil(setup.notifications.settings)
        XCTAssertNotNil(setup.notifications.error)
        XCTAssertNotNil(setup.account.notificationFailure)
        XCTAssertEqual(setup.account.headerStatus, .needsAttention)
    }

    func testCancelledPreferenceWritesStillReportAnUnconfirmedChange() async throws {
        let setup = try await make([settings(chores: false)], holdIndex: 1)
        let writing = Task {
            await setup.notifications.savePreferences(NotificationPreferences(chores: false, money: true))
        }
        await setup.transport.started.wait()
        writing.cancel()
        await setup.transport.finish.signal()
        await writing.value
        XCTAssertNil(setup.notifications.settings)
        XCTAssertNotNil(setup.notifications.error)
        XCTAssertEqual(setup.account.headerStatus, .needsAttention)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.httpMethod, "PUT")
    }

    func testCancelledSettingsReadsCannotClearAnEarlierUnconfirmedWrite() async throws {
        let setup = try await make([fixture.failure(503), settings(chores: false)], holdIndex: 2)
        await setup.notifications.savePreferences(NotificationPreferences(chores: false, money: true))
        let failure = try XCTUnwrap(setup.notifications.error)
        let reading = Task { await setup.notifications.refreshSettings() }
        await setup.transport.started.wait()
        reading.cancel()
        await setup.transport.finish.signal()
        await reading.value
        XCTAssertEqual(setup.notifications.error, failure)
        XCTAssertEqual(setup.account.notificationFailure, failure)
        XCTAssertEqual(setup.account.headerStatus, .needsAttention)
        XCTAssertNil(setup.notifications.settings)
    }

    func testExplicitEnableBindsOptInToTheAccountAndUploadsRefreshedTokens() async throws {
        let setup = try await make([settings(), response(["registered": true]), response(["registered": true])])
        await setup.notifications.enable()
        XCTAssertEqual(setup.system.requests, 1)
        XCTAssertEqual(setup.system.registrations, 1)
        XCTAssertTrue(setup.notifications.enabledOnDevice)
        XCTAssertFalse(setup.notifications.registered)
        XCTAssertTrue(setup.notifications.waitingForAPNs)
        let stored = await setup.store.value
        XCTAssertEqual(stored?.accountID, accountID)
        setup.notifications.receivedDeviceToken(Data([0xab, 0xcd]))
        await setup.notifications.synchronize()
        XCTAssertTrue(setup.notifications.registered)
        setup.notifications.receivedDeviceToken(Data([0xde, 0xfa]))
        await setup.notifications.synchronize()
        await waitUntil { setup.notifications.registered }
        let requests = await setup.transport.requests
        let uploads = requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(uploads.count, 2)
        let lastBody = try XCTUnwrap(uploads.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: lastBody) as? [String: String])
        XCTAssertEqual(body["token"], "defa")
        XCTAssertEqual(body["environment"], "sandbox")
        XCTAssertEqual(body["installationId"], stored?.id.uuidString.lowercased())
        XCTAssertNil(setup.notifications.error)
    }

    func testDeniedSystemPermissionDoesNotPersistConsentOrRegister() async throws {
        let setup = try await make([settings()], permission: .denied)
        await setup.notifications.enable()
        XCTAssertEqual(setup.system.requests, 0)
        XCTAssertEqual(setup.system.registrations, 0)
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertNotNil(setup.notifications.error)
        let saves = await setup.store.saves
        XCTAssertEqual(saves, 0)
    }

    func testMissingProviderConfigurationDoesNotTriggerAPermissionPrompt() async throws {
        let setup = try await make([settings(available: false)])
        await setup.notifications.enable()
        XCTAssertEqual(setup.system.requests, 0)
        XCTAssertEqual(setup.system.registrations, 0)
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.notifications.error, "Push notifications are not configured for this build or server yet.")
    }

    func testFailedKeychainConsentCannotStartRegistration() async throws {
        let setup = try await make([settings()], permission: .allowed)
        await setup.store.failWrites()
        await setup.notifications.enable()
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.system.registrations, 0)
        XCTAssertNotNil(setup.notifications.error)
    }

    func testAnotherAccountsOptInNeverRegistersTheCurrentAccount() async throws {
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: UUID())
        let setup = try await make([], installation: installation, permission: .allowed)
        await setup.notifications.synchronize()
        setup.notifications.receivedDeviceToken(Data([1, 2]))
        await setup.notifications.synchronize()
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.system.registrations, 0)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFailedUploadIsNotRetriedInAnAutomaticBusyLoop() async throws {
        let setup = try await make([
            settings(), fixture.failure(503), response(["registered": true]), settings()
        ], permission: .allowed)
        await setup.notifications.enable()
        setup.notifications.receivedDeviceToken(Data([1, 2]))
        await setup.notifications.synchronize()
        await waitUntil { setup.notifications.error != nil }
        XCTAssertFalse(setup.notifications.registered)
        await setup.notifications.synchronize()
        let failed = await setup.transport.requests
        XCTAssertEqual(failed.count, 3)
        await setup.notifications.retry()
        await waitUntil { setup.notifications.registered }
        XCTAssertNil(setup.notifications.error)
        let recovered = await setup.transport.requests
        XCTAssertEqual(recovered.filter { $0.httpMethod == "PUT" }.count, 2)
    }

    func testDisableStopsTheDeviceEvenWhenServerRemovalNeedsRetry() async throws {
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: accountID)
        let setup = try await make([
            fixture.failure(503), response(["removed": true]), settings()
        ], installation: installation, permission: .allowed)
        await setup.notifications.synchronize()
        await setup.notifications.disable()
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertFalse(setup.notifications.registered)
        XCTAssertEqual(setup.system.unregistrations, 1)
        XCTAssertEqual(setup.system.clears, 1)
        XCTAssertNotNil(setup.notifications.error)
        let disabled = await setup.store.value
        XCTAssertEqual(disabled, PushInstallation(id: installation.id, enabled: false))
        await setup.notifications.retry()
        XCTAssertNil(setup.notifications.error)
        XCTAssertEqual(setup.system.registrations, 1)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 2)
    }

    func testEveryLaunchRegistersAgainWithoutReusingATokenFromDisk() async throws {
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: accountID)
        let setup = try await make([response(["registered": true])], installation: installation, permission: .allowed)
        await setup.notifications.synchronize()
        setup.notifications.receivedDeviceToken(Data([1, 2]))
        await setup.notifications.synchronize()
        await waitUntil { setup.notifications.registered }
        let nextSystem = NotificationSystemDouble(permission: .allowed)
        let relaunched = NativeNotifications(system: nextSystem, environment: .sandbox)
        relaunched.attach(to: setup.account)
        await relaunched.synchronize()
        XCTAssertEqual(nextSystem.registrations, 1)
        XCTAssertTrue(relaunched.waitingForAPNs)
        XCTAssertFalse(relaunched.registered)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testForegroundNotificationsRespectMembershipAndCurrentPreferences() async throws {
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: accountID)
        let setup = try await make([settings(chores: true, money: false)],
                                   installation: installation, permission: .allowed)
        await setup.notifications.refreshSettings()
        let chore = try destination(kind: "chores")
        let expense = try destination(kind: "expense", entry: UUID())
        XCTAssertTrue(setup.notifications.canPresent(chore))
        XCTAssertFalse(setup.notifications.canPresent(expense))
        let foreign = try destination(kind: "chores", household: UUID())
        XCTAssertFalse(setup.notifications.canPresent(foreign))
    }

    func testMalformedNotificationCannotLeaveAnOlderDestinationPending() async throws {
        let setup = try await make([])
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "kind": "chores", "householdId": fixture.householdID.uuidString
        ])
        setup.notifications.receiveNotification(data)
        XCTAssertNotNil(setup.notifications.pending)
        setup.notifications.receiveNotification(Data("{\"version\":99}".utf8))
        XCTAssertNil(setup.notifications.pending)
        XCTAssertNotNil(setup.notifications.routingError)
        XCTAssertNotNil(setup.account.notificationFailure)
        setup.notifications.receiveNotification(data)
        XCTAssertNotNil(setup.notifications.pending)
        XCTAssertNil(setup.notifications.routingError)
        XCTAssertNil(setup.notifications.error)
    }

    func testConfirmedCredentialExpiryRemovesNativeNotificationAccess() async throws {
        let setup = try await make([fixture.failure(401, code: "ACCOUNT_SESSION_REQUIRED")])
        await setup.notifications.refreshSettings()
        XCTAssertFalse(setup.account.signedIn)
        XCTAssertNotNil(setup.notifications.error)
        setup.notifications.attach(to: setup.account)
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertNil(setup.notifications.settings)
    }

    func testConfirmedAccountDeletionDiscardsCachedConsentAndPendingNotificationTargets() async throws {
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: accountID)
        let setup = try await make([fixture.state(signedIn: false)], installation: installation, permission: .allowed)
        await setup.notifications.synchronize()
        setup.notifications.receiveNotification(try JSONSerialization.data(withJSONObject: [
            "version": 1, "kind": "chores", "householdId": fixture.householdID.uuidString
        ]))
        let deleted = await setup.account.deleteAccount(accountID: accountID, confirmation: "ada@example.test")
        XCTAssertTrue(deleted)
        setup.notifications.attach(to: setup.account)
        XCTAssertNil(setup.notifications.installation)
        XCTAssertNil(setup.notifications.pending)
        XCTAssertFalse(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.system.unregistrations, 1)
        let stored = await setup.store.value
        XCTAssertNil(stored)
    }

    func testDelayedNotificationPermissionCannotRestoreConsentAfterAccountDeletion() async throws {
        let setup = try await make([settings(), fixture.state(signedIn: false)], permission: .allowed)
        let gate = InvitationModelSignal()
        setup.system.permissionGate = gate
        let enabling = Task { await setup.notifications.enable() }
        await waitUntil { setup.notifications.settings != nil && !setup.account.busy }
        let deleted = await setup.account.deleteAccount(accountID: accountID, confirmation: "ada@example.test")
        XCTAssertTrue(deleted)
        setup.notifications.attach(to: setup.account)
        await gate.signal()
        await enabling.value
        XCTAssertEqual(setup.system.registrations, 0)
        let stored = await setup.store.value
        XCTAssertNotEqual(stored?.enabled, true)
        XCTAssertNil(stored?.accountID)
        XCTAssertNil(setup.notifications.error)
    }

    func testSameAccountReauthenticationRenewsTheSessionBoundPushRegistration() async throws {
        let response = try fixture.state(token: true)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        var devices = try XCTUnwrap(fields["devices"] as? [[String: Any]])
        devices[0]["id"] = UUID().uuidString
        fields["devices"] = devices
        let rotated = HTTPResponse(data: try JSONSerialization.data(withJSONObject: fields), statusCode: 200, url: fixture.api.origin)
        let installation = PushInstallation(id: UUID(), enabled: true, accountID: accountID)
        let setup = try await make([rotated], installation: installation, permission: .allowed)
        await setup.notifications.synchronize()
        XCTAssertEqual(setup.system.registrations, 1)
        let verified = await setup.account.reauthenticate(accountID: accountID, code: "123456", label: "iPhone")
        XCTAssertTrue(verified)
        setup.notifications.attach(to: setup.account)
        await setup.notifications.synchronize()
        XCTAssertEqual(setup.system.registrations, 2)
        XCTAssertTrue(setup.notifications.enabledOnDevice)
        XCTAssertEqual(setup.system.unregistrations, 0)
    }

    private func settings(chores: Bool = true, money: Bool = true, available: Bool = true) throws -> HTTPResponse {
        try response([
            "householdId": fixture.householdID.uuidString, "memberId": fixture.memberID,
            "preferences": ["chores": chores, "money": money], "pushAvailable": available
        ])
    }

    private func response(_ fields: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(data: try JSONSerialization.data(withJSONObject: fields), statusCode: 200, url: fixture.api.origin)
    }

    private func destination(kind: String, household: UUID? = nil, entry: UUID? = nil) throws -> NotificationDestination {
        var fields: [String: Any] = [
            "version": 1, "kind": kind, "householdId": (household ?? fixture.householdID).uuidString
        ]
        if let entry { fields[kind == "expense" ? "expenseId" : "settlementId"] = entry.uuidString }
        return try JSONDecoder().decode(NotificationDestination.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func make(
        _ responses: [HTTPResponse], installation: PushInstallation? = nil,
        permission: NotificationPermission = .notDetermined, holdIndex: Int? = nil
    ) async throws -> (notifications: NativeNotifications, account: AccountModel, store: NotificationInstallationDouble,
                       system: NotificationSystemDouble, transport: InvitationModelTransport) {
        let transport = InvitationModelTransport(responses: try [fixture.state()] + responses, holdIndex: holdIndex)
        let credential = InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let client = AccountSession(configuration: fixture.api, tokenStore: credential, transport: transport)
        let store = NotificationInstallationDouble(value: installation)
        let account = AccountModel(client: client, notificationStore: store)
        await account.start()
        let system = NotificationSystemDouble(permission: permission)
        let notifications = NativeNotifications(system: system, environment: .sandbox)
        notifications.attach(to: account)
        return (notifications, account, store, system, transport)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
}

private actor NotificationInstallationDouble: PushInstallationStore {
    private(set) var value: PushInstallation?
    private(set) var saves = 0
    private var writesFail = false

    init(value: PushInstallation?) { self.value = value }
    func read() -> PushInstallation? { value }
    func save(_ installation: PushInstallation) throws {
        if writesFail { throw KeychainError.invalidStoredPushInstallation }
        saves += 1
        value = installation
    }
    func clear() { value = nil }
    func failWrites() { writesFail = true }
}

@MainActor
private final class NotificationSystemDouble: NotificationSystem {
    var authorization: NotificationPermission
    var requests = 0
    var registrations = 0
    var unregistrations = 0
    var clears = 0
    var permissionGate: InvitationModelSignal?

    init(permission: NotificationPermission) { authorization = permission }
    func permission() async -> NotificationPermission {
        if let permissionGate { await permissionGate.wait() }
        return authorization
    }
    func requestPermission() -> Bool {
        requests += 1
        authorization = .allowed
        return true
    }
    func register() { registrations += 1 }
    func unregister() { unregistrations += 1 }
    func clearDelivered() { clears += 1 }
    func openSettings() -> Bool { true }
}
