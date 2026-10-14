import Foundation

/// The saved recovery-code set, without the codes themselves.
public struct AccountRecoveryStatus: Sendable, Equatable, Decodable {
    public static let codeCount = 10

    public let version: Int64
    public let remaining: Int
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey { case version, remaining, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int64.self, forKey: .version)
        remaining = try container.decode(Int.self, forKey: .remaining)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        guard (0..<HouseholdValidation.maximumInteger).contains(version), (0...Self.codeCount).contains(remaining),
              (version == 0) == (updatedAt == nil), version != 0 || remaining == 0 else {
            throw AccountError.invalidResponse
        }
    }
}

/// A newly generated set. The server never returns these codes again, so they are
/// kept out of descriptions, mirrors and logs.
public struct AccountRecoveryCodes: Sendable, Equatable, Decodable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let codes: [String]
    public let status: AccountRecoveryStatus

    private enum CodingKeys: String, CodingKey { case codes, recovery }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codes = try container.decode([String].self, forKey: .codes)
        status = try container.decode(AccountRecoveryStatus.self, forKey: .recovery)
        guard codes.count == AccountRecoveryStatus.codeCount, Set(codes).count == codes.count,
              codes.allSatisfy(AccountValidation.recoveryCode), status.remaining == codes.count else {
            throw AccountError.invalidResponse
        }
    }

    public var description: String { "AccountRecoveryCodes(version: \(status.version))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["version": status.version]) }
}

private struct RecoveryVersionRequest: Encodable, Sendable { let version: Int64 }
private struct ProfileRequest: Encodable, Sendable { let name: String }
private struct DeviceLabelRequest: Encodable, Sendable { let label: String }

extension AccountAPI {
    func recoveryStatus(token: SessionToken) async throws -> AccountRecoveryStatus {
        try await client.request(.recoveryStatus, token: token)
    }

    func generateRecoveryCodes(version: Int64, token: SessionToken) async throws -> AccountRecoveryCodes {
        let result: AccountRecoveryCodes = try await client.request(
            .generateRecoveryCodes, body: JSONEncoder().encode(RecoveryVersionRequest(version: version)), token: token
        )
        guard result.status.version > version else { throw AccountError.invalidResponse }
        return result
    }

    func revokeRecoveryCodes(version: Int64, token: SessionToken) async throws -> AccountRecoveryStatus {
        let status: AccountRecoveryStatus = try await client.request(
            .revokeRecoveryCodes, body: JSONEncoder().encode(RecoveryVersionRequest(version: version)), token: token
        )
        guard status.version > version, status.remaining == 0 else { throw AccountError.invalidResponse }
        return status
    }

    func updateProfile(name: String, token: SessionToken) async throws -> AccountState {
        let name = try nameInput(name, field: .name)
        let response: OrdinaryAccountResponse = try await client.request(
            .updateProfile, body: JSONEncoder().encode(ProfileRequest(name: name)), token: token
        )
        guard response.state.account?.name == name else { throw AccountError.invalidResponse }
        return response.state
    }

    func renameDevice(label: String, token: SessionToken) async throws -> AccountState {
        let label = try nameInput(label, field: .deviceLabel)
        let response: OrdinaryAccountResponse = try await client.request(
            .renameDevice, body: JSONEncoder().encode(DeviceLabelRequest(label: label)), token: token
        )
        guard response.state.devices.first(where: \.current)?.label == label else { throw AccountError.invalidResponse }
        return response.state
    }

    func revokeDevice(id: UUID, token: SessionToken) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await client.request(.revokeDevice(id), token: token)
        guard !response.state.devices.contains(where: { $0.id == id }) else { throw AccountError.invalidResponse }
        return response.state
    }
}
