import Foundation
@testable import RoomlingsCore

enum Fixtures {
    static let configuration = try! APIConfiguration(origin: "https://api.roomlings.example", requestTimeout: 12)
    static let oldToken = try! SessionToken(String(repeating: "a", count: 43))
    static let newToken = try! SessionToken(String(repeating: "b", count: 43))
    static let recoveryCode = "roomlings-account-abcd-1234-abcd-1234-abcd-1234-abcd-1234"
    static let householdID = "11111111-1111-4111-8111-111111111111"
    static let memberID = "22222222-2222-4222-8222-222222222222"
    static let accountID = "33333333-3333-4333-8333-333333333333"
    static let deviceID = "44444444-4444-4444-8444-444444444444"

    static var account: JSONValue {
        .object([
            "id": .string(accountID), "email": .string("roommate@example.com"),
            "name": .string("Roommate"), "createdAt": .string("2026-09-13T12:00:00.000Z")
        ])
    }

    static var device: JSONValue {
        .object([
            "id": .string(deviceID), "label": .string("iPhone"),
            "createdAt": .string("2026-09-13T12:00:00.000Z"),
            "lastUsedAt": .string("2026-09-13T13:00:00Z"),
            "expiresAt": .string("2026-10-13T12:00:00.000Z"), "current": .bool(true)
        ])
    }

    static var membership: JSONValue {
        .object([
            "householdId": .string(householdID), "householdName": .string("Our kitchen"),
            "memberId": .string(memberID), "currency": .string("EUR"), "role": .string("owner")
        ])
    }

    static var household: JSONValue {
        .object([
            "id": .string(householdID), "name": .string("Our kitchen"),
            "currency": .string("EUR"), "budget": .integer(45_000), "version": .integer(17),
            "inviteCode": .string("test-only-invite"),
            "members": .array([.object([
                "id": .string(memberID), "name": .string("Roommate"), "color": .string("#7d9070")
            ])]),
            "expenses": .array([.object(["amount": .integer(1_999)])]),
            "settlements": .array([]), "unrecognizedServerField": .integer(9_007_199_254_740_993)
        ])
    }

    static func state(
        signedIn: Bool = true, token: SessionToken? = nil,
        selectedHousehold: Bool = false, deletionPending: Bool = false
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "configured": .bool(true),
            "account": signedIn ? account : .null,
            "memberships": .array(selectedHousehold ? [membership] : []),
            "devices": .array(signedIn ? [device] : []),
            "csrfToken": signedIn ? .string(String(repeating: "c", count: 64)) : .null,
            "session": selectedHousehold
                ? .object(["token": .null, "memberId": .string(memberID), "household": household])
                : .null
        ]
        if let token { object["accessToken"] = .string(token.value) }
        if deletionPending { object["deletionPending"] = .bool(true) }
        return object
    }

    static func data(_ object: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(object))
    }

    static func response(
        _ object: [String: JSONValue], status: Int = 200, path: String = "api/account"
    ) throws -> HTTPResponse {
        HTTPResponse(
            data: try data(object), statusCode: status,
            url: configuration.origin.appendingPathComponent(path)
        )
    }

    static func failure(status: Int, code: String?) throws -> HTTPResponse {
        var object: [String: JSONValue] = ["error": .string("Sensitive server text \(oldToken.value)")]
        if let code { object["code"] = .string(code) }
        return try response(object, status: status)
    }
}

actor TestTransport: HTTPTransport {
    private let handler: @Sendable (URLRequest, Int) async throws -> HTTPResponse
    private(set) var requests: [URLRequest] = []

    init(response: HTTPResponse) {
        handler = { _, _ in response }
    }

    init(responses: [HTTPResponse]) {
        handler = { _, index in
            guard responses.indices.contains(index) else { throw TestFailure.unexpectedRequest }
            return responses[index]
        }
    }

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request, requests.count - 1)
    }
}

enum TestFailure: Error {
    case unexpectedRequest, storage
}

struct SensitiveFailure: Error {
    let detail: String
}

actor Signal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

actor MemoryTokenStore: SessionTokenStore {
    private(set) var token: SessionToken?
    private(set) var saveAttempts = 0
    private(set) var clearAttempts = 0
    private(set) var readAttempts = 0
    var readFailure: (any Error)?
    var saveFailure: (any Error)?
    var clearFailure: (any Error)?
    let saveStarted: Signal?
    let finishSave: Signal?

    init(
        token: SessionToken? = nil,
        readFailure: (any Error)? = nil,
        saveFailure: (any Error)? = nil,
        clearFailure: (any Error)? = nil,
        saveStarted: Signal? = nil,
        finishSave: Signal? = nil
    ) {
        self.token = token
        self.readFailure = readFailure
        self.saveFailure = saveFailure
        self.clearFailure = clearFailure
        self.saveStarted = saveStarted
        self.finishSave = finishSave
    }

    func read() async throws -> SessionToken? {
        readAttempts += 1
        if let readFailure { throw readFailure }
        return token
    }

    func save(_ token: SessionToken) async throws {
        saveAttempts += 1
        await saveStarted?.signal()
        await finishSave?.wait()
        if let saveFailure { throw saveFailure }
        self.token = token
    }

    func clear() async throws {
        clearAttempts += 1
        if let clearFailure { throw clearFailure }
        token = nil
    }
}
