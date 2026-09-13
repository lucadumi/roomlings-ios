import Foundation
import Security

public struct SessionToken: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) throws {
        guard value.utf8.count == 43, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw SessionTokenError.invalidToken }
        self.value = value
    }

    public var description: String { "SessionToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

public enum SessionTokenError: Error, Sendable, LocalizedError {
    case invalidToken

    public var errorDescription: String? { "The account credential has an invalid format." }
}

public protocol SessionTokenStore: Sendable {
    /// Return nil only when no credential is stored. Locked or corrupt storage must throw.
    func read() async throws -> SessionToken?
    /// Replace atomically without deleting a good credential before the new one is stored.
    func save(_ token: SessionToken) async throws
    func clear() async throws
}

public enum KeychainOperation: String, Sendable {
    case read, update, add, clear
}

public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidStoredCredential
    case status(operation: KeychainOperation, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Keychain service and account must not be empty."
        case .invalidStoredCredential: "The saved account credential is unreadable."
        case .status(let operation, let status): "Keychain \(operation.rawValue) failed (OSStatus \(status))."
        }
    }
}

public actor KeychainSessionTokenStore: SessionTokenStore {
    private let service: String
    private let account: String
    private let operations: any KeychainOperations

    public init(service: String, account: String = "account-session") throws {
        try self.init(service: service, account: account, operations: SystemKeychainOperations())
    }

    init(service: String, account: String, operations: any KeychainOperations) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError.invalidConfiguration
        }
        self.service = service
        self.account = account
        self.operations = operations
    }

    public func read() async throws -> SessionToken? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copyMatching(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: .read)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8),
              let token = try? SessionToken(value) else { throw KeychainError.invalidStoredCredential }
        return token
    }

    public func save(_ token: SessionToken) async throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = operations.update(item as CFDictionary, attributes: attributes as CFDictionary)
        if status == errSecItemNotFound {
            let newItem = item.merging(attributes) { _, value in value }
            let added = operations.add(newItem as CFDictionary)
            if added == errSecDuplicateItem {
                // Another writer may have created the same item between update and add.
                try check(operations.update(item as CFDictionary, attributes: attributes as CFDictionary), operation: .update)
            } else {
                try check(added, operation: .add)
            }
        } else {
            try check(status, operation: .update)
        }
    }

    public func clear() async throws {
        let status = operations.delete(item as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: .clear) }
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func check(_ status: OSStatus, operation: KeychainOperation) throws {
        guard status == errSecSuccess else { throw KeychainError.status(operation: operation, status: status) }
    }
}

protocol KeychainOperations: Sendable {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?)
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemKeychainOperations: KeychainOperations {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}
