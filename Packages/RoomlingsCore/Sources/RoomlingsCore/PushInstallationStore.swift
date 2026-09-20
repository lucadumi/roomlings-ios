import Foundation
import Security

public struct PushInstallation: Codable, Sendable, Equatable {
    public let id: UUID
    public let enabled: Bool
    public let accountID: UUID?

    public init(id: UUID, enabled: Bool, accountID: UUID? = nil) {
        self.id = id
        self.enabled = enabled
        self.accountID = accountID
    }

    public init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        guard Set(fields.object.keys).isSubset(of: ["id", "enabled", "accountID"]),
              let id = UUID(uuidString: try fields.string("id")) else { throw AccountError.invalidResponse }
        self.id = id
        enabled = try fields.bool("enabled")
        if let rawAccountID = try fields.nullableString("accountID", optional: true) {
            guard let accountID = UUID(uuidString: rawAccountID) else { throw AccountError.invalidResponse }
            self.accountID = accountID
        } else {
            accountID = nil
        }
    }
}

public protocol PushInstallationStore: Sendable {
    /// Return nil only when no installation is stored. Locked or corrupt storage must throw.
    func read() async throws -> PushInstallation?
    func save(_ installation: PushInstallation) async throws
    func clear() async throws
}

public actor KeychainPushInstallationStore: PushInstallationStore {
    private let service: String
    private let account: String
    private let operations: any KeychainOperations

    public init(service: String, account: String = "push-installation") throws {
        try self.init(service: service, account: account, operations: SystemKeychainOperations())
    }

    init(service: String, account: String = "push-installation", operations: any KeychainOperations) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError.invalidConfiguration
        }
        self.service = service
        self.account = account
        self.operations = operations
    }

    public func read() async throws -> PushInstallation? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copyMatching(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: .read)
        guard let data = result as? Data,
              let installation = try? JSONDecoder().decode(PushInstallation.self, from: data) else {
            throw KeychainError.invalidStoredPushInstallation
        }
        return installation
    }

    public func save(_ installation: PushInstallation) async throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(installation),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = operations.update(item as CFDictionary, attributes: attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = operations.add(item.merging(attributes) { _, value in value } as CFDictionary)
            if added == errSecDuplicateItem {
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
