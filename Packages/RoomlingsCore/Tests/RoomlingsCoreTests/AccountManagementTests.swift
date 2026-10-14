import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Account management", .timeLimit(.minutes(1)))
struct AccountManagementTests {
    private let otherDeviceID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

    @Test
    func generatingCodesSendsTheVersionAndKeepsCodesOutOfDescriptions() async throws {
        let codes = (0..<10).map { index in "roomlings-account-" + Array(repeating: String(format: "%04x", index), count: 8).joined(separator: "-") }
        let (session, transport) = try await make(replies: [
            try Fixtures.response(["codes": .array(codes.map(JSONValue.string)), "recovery": .object(status(version: 4, remaining: 10))]),
        ])
        let result = try await session.generateRecoveryCodes(version: 3)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/account/recovery")
        #expect(try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) == .object(["version": .integer(3)]))
        #expect(result.codes == codes)
        #expect(result.status.version == 4)
        for text in [String(describing: result), String(reflecting: result), "\(Mirror(reflecting: result).children.map(\.value))"] {
            #expect(!codes.contains(where: text.contains))
        }
    }

    @Test
    func incompleteOrRepeatedCodeSetsAreRejected() async throws {
        let code = "roomlings-account-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa"
        for codes in [Array(repeating: code, count: 10), [code]] {
            let (session, _) = try await make(replies: [
                try Fixtures.response(["codes": .array(codes.map(JSONValue.string)), "recovery": .object(status(version: 4, remaining: 10))]),
            ])
            await #expect(throws: AccountError.invalidResponse) { try await session.generateRecoveryCodes(version: 3) }
        }
    }

    @Test
    func revokingCodesUsesDeleteWithTheVersionAndNeedsAnEmptySet() async throws {
        let (session, transport) = try await make(replies: [try Fixtures.response(status(version: 5, remaining: 0))])
        let revoked = try await session.revokeRecoveryCodes(version: 4)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/account/recovery")
        #expect(revoked.remaining == 0)
        let (stale, _) = try await make(replies: [try Fixtures.response(status(version: 5, remaining: 3))])
        await #expect(throws: AccountError.invalidResponse) { try await stale.revokeRecoveryCodes(version: 4) }
    }

    @Test
    func recoveryChangesThatNeedAFreshSignInAreNotRetried() async throws {
        let (session, transport) = try await make(replies: [try Fixtures.failure(status: 401, code: "REAUTHENTICATION_REQUIRED")])
        await #expect(throws: AccountError.server(status: 401, code: .reauthenticationRequired)) {
            try await session.generateRecoveryCodes(version: 0)
        }
        #expect(await transport.requests.count == 2)
        #expect(await session.state?.isSignedIn == true)
    }

    @Test
    func profileAndDeviceNamesComeBackFromTheServer() async throws {
        var renamed = Fixtures.state()
        renamed["account"] = Self.replacing(Fixtures.account, "name", "Ada Lovelace")
        var relabelled = renamed
        relabelled["devices"] = .array([Self.replacing(Fixtures.device, "label", "Kitchen iPad")])
        let (session, transport) = try await make(replies: [try Fixtures.response(renamed), try Fixtures.response(relabelled)])
        try await session.updateProfile(name: "  Ada Lovelace ")
        #expect(await session.state?.account?.name == "Ada Lovelace")
        try await session.renameDevice(label: "Kitchen iPad")
        #expect(await session.state?.devices.first?.label == "Kitchen iPad")
        let requests = await transport.requests
        #expect(requests[1].httpMethod == "PATCH" && requests[1].url?.path == "/api/account")
        #expect(requests[2].httpMethod == "PATCH" && requests[2].url?.path == "/api/account/device")
    }

    @Test
    func onlyAnotherDeviceCanBeRevokedHere() async throws {
        var initial = Fixtures.state()
        initial["devices"] = .array([Fixtures.device, other])
        let (session, transport) = try await make(initial: initial, replies: [try Fixtures.response(Fixtures.state())])
        let current = UUID(uuidString: Fixtures.deviceID)!
        await #expect(throws: AccountError.invalidInput(.deviceID)) { try await session.revokeDevice(id: current) }
        #expect(await transport.requests.count == 1)
        try await session.revokeDevice(id: otherDeviceID)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/account/devices/\(otherDeviceID.uuidString.lowercased())")
        #expect(await session.state?.devices.map(\.id) == [current])
    }

    @Test
    func aResponseForAnotherDeviceOrAccountIsRejected() async throws {
        var swapped = Fixtures.state()
        swapped["devices"] = .array([Self.replacing(Self.replacing(Fixtures.device, "current", false), "label", "iPhone"), Self.replacing(other, "current", true)])
        let (session, _) = try await make(replies: [try Fixtures.response(swapped)])
        await #expect(throws: AccountError.invalidResponse) { try await session.renameDevice(label: "iPhone") }
        #expect(await session.state?.devices.first(where: \.current)?.id == UUID(uuidString: Fixtures.deviceID))
    }

    // MARK: - Fixtures

    private var other: JSONValue {
        Self.replacing(Self.replacing(Self.replacing(Fixtures.device, "id", otherDeviceID.uuidString.lowercased()), "current", false), "label", "Old laptop")
    }

    private func status(version: Int64, remaining: Int64) -> [String: JSONValue] {
        [
            "version": .integer(version), "remaining": .integer(remaining),
            "updatedAt": version == 0 ? .null : .string("2026-10-14T12:00:00.000Z"),
        ]
    }

    private static func replacing(_ value: JSONValue, _ key: String, _ replacement: String) -> JSONValue {
        replacing(value, key, JSONValue.string(replacement))
    }

    private static func replacing(_ value: JSONValue, _ key: String, _ replacement: Bool) -> JSONValue {
        replacing(value, key, JSONValue.bool(replacement))
    }

    private static func replacing(_ value: JSONValue, _ key: String, _ replacement: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return value }
        object[key] = replacement
        return .object(object)
    }

    private func make(
        initial: [String: JSONValue] = Fixtures.state(), replies: [HTTPResponse]
    ) async throws -> (AccountSession, TestTransport) {
        let transport = TestTransport(responses: [try Fixtures.response(initial)] + replies)
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        return (session, transport)
    }
}
