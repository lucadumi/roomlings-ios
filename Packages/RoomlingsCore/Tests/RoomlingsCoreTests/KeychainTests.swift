import Foundation
import Security
import Testing
@testable import RoomlingsCore

@Suite("Isolated Keychain adapter")
struct KeychainTests {
    @Test
    func missingItemIsTheOnlyNilRead() async throws {
        let operations = FakeKeychain(readStatus: errSecItemNotFound)
        let store = try makeStore(operations)
        #expect(try await store.read() == nil)
        #expect(operations.calls.map(\.operation) == [.read])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func readFailuresExposeExactStatus(status: OSStatus) async throws {
        let store = try makeStore(FakeKeychain(readStatus: status))
        await #expect(throws: KeychainError.status(operation: .read, status: status)) {
            try await store.read()
        }
    }

    @Test(arguments: [nil, Data([0xff]), Data("invalid-credential".utf8)] as [Data?])
    func successfulReadsWithCorruptDataAreNotSignedOut(data: Data?) async throws {
        let store = try makeStore(FakeKeychain(data: data))
        await #expect(throws: KeychainError.invalidStoredCredential) { try await store.read() }
    }

    @Test
    func replacementUpdatesInPlaceWithDeviceOnlyAccessibility() async throws {
        let operations = FakeKeychain(data: Data(Fixtures.oldToken.value.utf8))
        let store = try makeStore(operations)
        #expect(try await store.read() == Fixtures.oldToken)
        try await store.save(Fixtures.newToken)
        #expect(try await store.read() == Fixtures.newToken)
        #expect(operations.calls.map(\.operation) == [.read, .update, .read])
        let update = try #require(operations.calls.first(where: { $0.operation == .update }))
        #expect(update.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        for call in operations.calls {
            #expect(call.service == "RoomlingsCoreTests.injected-only")
            #expect(call.account == "isolated-account")
            #expect(call.synchronizable == false)
            #expect(call.dataProtection == true)
        }
    }

    @Test
    func newItemAddsOnlyAfterNotFound() async throws {
        let operations = FakeKeychain(updateStatuses: [errSecItemNotFound])
        let store = try makeStore(operations)
        try await store.save(Fixtures.newToken)
        #expect(operations.calls.map(\.operation) == [.update, .add])
        #expect(operations.storedData == Data(Fixtures.newToken.value.utf8))
        #expect(operations.calls.last?.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test
    func failedReplacementNeverDeletesAGoodCredential() async throws {
        let original = Data(Fixtures.oldToken.value.utf8)
        let operations = FakeKeychain(data: original, updateStatuses: [errSecInteractionNotAllowed])
        let store = try makeStore(operations)
        await #expect(throws: KeychainError.status(operation: .update, status: errSecInteractionNotAllowed)) {
            try await store.save(Fixtures.newToken)
        }
        #expect(operations.storedData == original)
        #expect(operations.calls.map(\.operation) == [.update])
    }

    @Test
    func addFailureSurfacesItsStatus() async throws {
        let operations = FakeKeychain(updateStatuses: [errSecItemNotFound], addStatus: errSecNotAvailable)
        let store = try makeStore(operations)
        await #expect(throws: KeychainError.status(operation: .add, status: errSecNotAvailable)) {
            try await store.save(Fixtures.newToken)
        }
        #expect(operations.calls.map(\.operation) == [.update, .add])
        #expect(operations.storedData == nil)
    }

    @Test
    func duplicateDuringAddRetriesOnlyTheAtomicLocalUpdate() async throws {
        let operations = FakeKeychain(
            updateStatuses: [errSecItemNotFound, errSecSuccess], addStatus: errSecDuplicateItem
        )
        let store = try makeStore(operations)
        try await store.save(Fixtures.newToken)
        #expect(operations.calls.map(\.operation) == [.update, .add, .update])
        #expect(operations.storedData == Data(Fixtures.newToken.value.utf8))
    }

    @Test(arguments: [errSecSuccess, errSecItemNotFound])
    func clearingAbsentOrPresentCredentialSucceeds(status: OSStatus) async throws {
        let operations = FakeKeychain(deleteStatus: status)
        let store = try makeStore(operations)
        try await store.clear()
        #expect(operations.calls.map(\.operation) == [.clear])
    }

    @Test
    func failedClearPreservesCredentialAndExposesStatus() async throws {
        let original = Data(Fixtures.oldToken.value.utf8)
        let operations = FakeKeychain(data: original, deleteStatus: errSecAuthFailed)
        let store = try makeStore(operations)
        await #expect(throws: KeychainError.status(operation: .clear, status: errSecAuthFailed)) {
            try await store.clear()
        }
        #expect(operations.storedData == original)
    }

    @Test
    func coordinatorDoesNotHideKeychainStatusOrSendUnauthenticatedFallbacks() async throws {
        let store = try makeStore(FakeKeychain(readStatus: errSecInteractionNotAllowed))
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(signedIn: false)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: KeychainError.status(operation: .read, status: errSecInteractionNotAllowed)) {
            try await session.restore()
        }
        #expect(await transport.requests.isEmpty)
        #expect(await session.state == nil)
    }

    @Test
    func rejectsEmptyServiceOrAccountWithoutKeychainAccess() {
        #expect(throws: KeychainError.invalidConfiguration) {
            try KeychainSessionTokenStore(service: " ")
        }
        #expect(throws: KeychainError.invalidConfiguration) {
            try KeychainSessionTokenStore(service: "RoomlingsCoreTests.injected-only", account: "")
        }
    }

    private func makeStore(_ operations: FakeKeychain) throws -> KeychainSessionTokenStore {
        try KeychainSessionTokenStore(
            service: "RoomlingsCoreTests.injected-only", account: "isolated-account", operations: operations
        )
    }
}

private struct KeychainCall: Sendable {
    let operation: KeychainOperation
    let service: String?
    let account: String?
    let accessibility: String?
    let synchronizable: Bool?
    let dataProtection: Bool?

    init(_ operation: KeychainOperation, query: CFDictionary, attributes: CFDictionary? = nil) {
        let query = query as! [String: Any]
        let attributes = attributes.map { $0 as! [String: Any] } ?? query
        self.operation = operation
        service = query[kSecAttrService as String] as? String
        account = query[kSecAttrAccount as String] as? String
        accessibility = attributes[kSecAttrAccessible as String] as? String
        synchronizable = query[kSecAttrSynchronizable as String] as? Bool
        dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool
    }
}

private final class FakeKeychain: KeychainOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var recordedCalls: [KeychainCall] = []
    private var updateStatuses: [OSStatus]
    private let readStatus: OSStatus
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus

    init(
        data: Data? = nil, readStatus: OSStatus = errSecSuccess,
        updateStatuses: [OSStatus] = [errSecSuccess],
        addStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess
    ) {
        self.data = data
        self.readStatus = readStatus
        self.updateStatuses = updateStatuses
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    var calls: [KeychainCall] { lock.withLock { recordedCalls } }
    var storedData: Data? { lock.withLock { data } }

    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        lock.withLock {
            recordedCalls.append(KeychainCall(.read, query: query))
            return (readStatus, data.map { $0 as CFData })
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(KeychainCall(.update, query: query, attributes: attributes))
            let status = updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
            if status == errSecSuccess { data = (attributes as! [String: Any])[kSecValueData as String] as? Data }
            return status
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(KeychainCall(.add, query: attributes))
            if addStatus == errSecSuccess { data = (attributes as! [String: Any])[kSecValueData as String] as? Data }
            return addStatus
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(KeychainCall(.clear, query: query))
            if deleteStatus == errSecSuccess { data = nil }
            return deleteStatus
        }
    }
}
