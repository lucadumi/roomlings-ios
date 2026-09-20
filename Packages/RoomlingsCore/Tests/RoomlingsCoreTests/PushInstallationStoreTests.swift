import Foundation
import Security
import Testing
@testable import RoomlingsCore

@Suite("Push installation persistence")
struct PushInstallationStoreTests {
    private let initial = PushInstallation(id: NotificationFixtures.installationID, enabled: false)
    private let enabled = PushInstallation(
        id: NotificationFixtures.installationID, enabled: true, accountID: UUID(uuidString: Fixtures.accountID)!
    )

    @Test
    func installationCodableContainsOnlyIdentityAndAccountBoundOptIn() throws {
        let data = try JSONEncoder().encode(enabled)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let fields = try HouseholdFields(value)
        #expect(Set(fields.object.keys) == ["id", "enabled", "accountID"])
        #expect(try fields.uuid("id") == enabled.id)
        #expect(try fields.bool("enabled"))
        #expect(try fields.uuid("accountID") == enabled.accountID)
        #expect(try JSONDecoder().decode(PushInstallation.self, from: data) == enabled)
    }

    @Test(arguments: ["absent", "null"], [true, false])
    func missingAccountBindingNeverTransfersOptInToARestoredAccount(kind: String, isEnabled: Bool) async throws {
        var fields: [String: JSONValue] = ["id": .string(initial.id.uuidString), "enabled": .bool(isEnabled)]
        if kind == "null" { fields["accountID"] = .null }
        let operations = FakeKeychain(data: try Fixtures.data(fields))
        let persistence = try store(operations)
        let installation = try #require(await persistence.read())
        #expect(installation.id == initial.id)
        #expect(installation.enabled == isEnabled)
        #expect(installation.accountID == nil)
        let canAutomaticallyRegister = installation.enabled && installation.accountID == UUID(uuidString: Fixtures.accountID)!
        #expect(!canAutomaticallyRegister)
        try await persistence.save(installation)
        let restored = try #require(await store(operations).read())
        #expect(restored == installation)
    }

    @Test
    func disablingRemovesAccountBindingWithoutRotatingTheInstallation() async throws {
        let operations = FakeKeychain(data: try JSONEncoder().encode(enabled))
        let persistence = try store(operations)
        let disabled = PushInstallation(id: enabled.id, enabled: false)
        #expect(disabled.accountID == nil)
        try await persistence.save(disabled)
        let restored = try #require(await store(operations).read())
        #expect(restored == disabled)
        #expect(restored.id == enabled.id)
        let fields = try HouseholdFields(JSONDecoder().decode(JSONValue.self, from: #require(operations.storedData)))
        #expect(Set(fields.object.keys) == ["id", "enabled"])
        #expect(operations.calls.map(\.operation) == [.update, .read])
    }

    @Test
    func onlyMissingStorageReturnsNil() async throws {
        let operations = FakeKeychain(readStatus: errSecItemNotFound)
        #expect(try await store(operations).read() == nil)
        #expect(operations.calls.map(\.operation) == [.read])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func lockedOrFailedReadsAreNotAFirstInstallation(status: OSStatus) async throws {
        await #expect(throws: KeychainError.status(operation: .read, status: status)) {
            try await store(FakeKeychain(readStatus: status)).read()
        }
    }

    @Test(arguments: [
        "nil", "encoding", "json", "missing-id", "missing-enabled", "bad-id", "bad-enabled",
        "bad-account", "wrong-account-type", "null", "apns-token", "credential"
    ])
    func corruptItemsNeverResetOptInOrGenerateAnotherIdentity(fault: String) async throws {
        var fields: [String: JSONValue] = [
            "id": .string(initial.id.uuidString), "enabled": .bool(initial.enabled)
        ]
        let data: Data?
        switch fault {
        case "nil": data = nil
        case "encoding": data = Data([0xff])
        case "json": data = Data("{".utf8)
        case "null": data = Data("null".utf8)
        default:
            switch fault {
            case "missing-id": fields.removeValue(forKey: "id")
            case "missing-enabled": fields.removeValue(forKey: "enabled")
            case "bad-id": fields["id"] = .string("not-an-installation")
            case "bad-enabled": fields["enabled"] = .integer(1)
            case "bad-account": fields["accountID"] = .string("not-an-account")
            case "wrong-account-type": fields["accountID"] = .bool(true)
            case "apns-token": fields["token"] = .string(NotificationFixtures.deviceToken.value)
            default: fields["accessToken"] = .string(Fixtures.oldToken.value)
            }
            data = try Fixtures.data(fields)
        }
        let operations = FakeKeychain(data: data)
        await #expect(throws: KeychainError.invalidStoredPushInstallation) { try await store(operations).read() }
        #expect(operations.calls.map(\.operation) == [.read])
    }

    @Test
    func updatesPersistAcrossStoreInstancesWithoutDeletingAGoodItem() async throws {
        let operations = FakeKeychain(data: try JSONEncoder().encode(initial))
        let first = try store(operations)
        #expect(try await first.read() == initial)
        try await first.save(enabled)
        let relaunched = try store(operations)
        #expect(try await relaunched.read() == enabled)
        #expect(operations.calls.map(\.operation) == [.read, .update, .read])
        #expect(operations.calls[1].accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        for call in operations.calls {
            #expect(call.service == "RoomlingsCoreTests.push-installation")
            #expect(call.account == "push-installation")
            #expect(call.synchronizable == false)
            #expect(call.dataProtection == true)
        }
    }

    @Test
    func newInstallationsAreAddedOnlyAfterNotFound() async throws {
        let operations = FakeKeychain(updateStatuses: [errSecItemNotFound])
        try await store(operations).save(initial)
        #expect(operations.calls.map(\.operation) == [.update, .add])
        #expect(operations.calls.last?.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(try JSONDecoder().decode(PushInstallation.self, from: #require(operations.storedData)) == initial)
    }

    @Test
    func serviceAndCustomAccountRemainExplicit() async throws {
        let operations = FakeKeychain(readStatus: errSecItemNotFound)
        let configured = try KeychainPushInstallationStore(
            service: "bundle.api-origin.notifications", account: "other-installation", operations: operations
        )
        #expect(try await configured.read() == nil)
        #expect(operations.calls.first?.service == "bundle.api-origin.notifications")
        #expect(operations.calls.first?.account == "other-installation")
    }

    @Test
    func aSharedOriginScopedServiceKeepsCredentialsAndInstallationSeparate() async throws {
        let service = "bundle.api-origin"
        let operations = FakeKeychain(readStatus: errSecItemNotFound)
        let credentials = try KeychainSessionTokenStore(service: service, account: "account-session", operations: operations)
        let installation = try KeychainPushInstallationStore(service: service, operations: operations)
        #expect(try await credentials.read() == nil)
        #expect(try await installation.read() == nil)
        #expect(operations.calls.map(\.service) == [service, service])
        #expect(operations.calls.map(\.account) == ["account-session", "push-installation"])
    }

    @Test(arguments: [true, false])
    func failedUpdatePreservesTheOldExplicitOptIn(disabling: Bool) async throws {
        let original = try JSONEncoder().encode(disabling ? enabled : initial)
        let operations = FakeKeychain(data: original, updateStatuses: [errSecInteractionNotAllowed])
        await #expect(throws: KeychainError.status(operation: .update, status: errSecInteractionNotAllowed)) {
            try await store(operations).save(disabling ? initial : enabled)
        }
        #expect(operations.storedData == original)
        #expect(operations.calls.map(\.operation) == [.update])
    }

    @Test
    func failedAddIsNotReportedAsSaved() async throws {
        let operations = FakeKeychain(updateStatuses: [errSecItemNotFound], addStatus: errSecNotAvailable)
        await #expect(throws: KeychainError.status(operation: .add, status: errSecNotAvailable)) {
            try await store(operations).save(enabled)
        }
        #expect(operations.storedData == nil)
        #expect(operations.calls.map(\.operation) == [.update, .add])
    }

    @Test(arguments: [errSecSuccess, errSecAuthFailed])
    func duplicateAddRetriesOneAtomicUpdateAndSurfacesItsFailure(status: OSStatus) async throws {
        let original = try JSONEncoder().encode(initial)
        let operations = FakeKeychain(
            data: original, updateStatuses: [errSecItemNotFound, status], addStatus: errSecDuplicateItem
        )
        if status == errSecSuccess {
            try await store(operations).save(enabled)
            #expect(try JSONDecoder().decode(PushInstallation.self, from: #require(operations.storedData)) == enabled)
        } else {
            await #expect(throws: KeychainError.status(operation: .update, status: status)) {
                try await store(operations).save(enabled)
            }
            #expect(operations.storedData == original)
        }
        #expect(operations.calls.map(\.operation) == [.update, .add, .update])
    }

    @Test(arguments: [errSecSuccess, errSecItemNotFound])
    func removingPresentOrMissingInstallationSucceeds(status: OSStatus) async throws {
        let operations = FakeKeychain(deleteStatus: status)
        try await store(operations).clear()
        #expect(operations.calls.map(\.operation) == [.clear])
    }

    @Test
    func failedClearPreservesTheInstallation() async throws {
        let original = try JSONEncoder().encode(enabled)
        let operations = FakeKeychain(data: original, deleteStatus: errSecAuthFailed)
        await #expect(throws: KeychainError.status(operation: .clear, status: errSecAuthFailed)) {
            try await store(operations).clear()
        }
        #expect(operations.storedData == original)
    }

    @Test
    func invalidConfigurationDoesNotAccessTheKeychain() {
        #expect(throws: KeychainError.invalidConfiguration) { try KeychainPushInstallationStore(service: " ") }
        #expect(throws: KeychainError.invalidConfiguration) {
            try KeychainPushInstallationStore(service: "RoomlingsCoreTests.push-installation", account: "\n")
        }
    }

    private func store(_ operations: FakeKeychain) throws -> KeychainPushInstallationStore {
        try KeychainPushInstallationStore(service: "RoomlingsCoreTests.push-installation", operations: operations)
    }
}
