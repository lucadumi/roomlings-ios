import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native transport")
struct TransportTests {
    @Test(arguments: [
        "https://api.roomlings.example", "https://api.roomlings.example/",
        "https://api.roomlings.example:8443", "https://127.0.0.1",
        "http://localhost:3001", "http://127.0.0.1:5173/", "http://[::1]:3001",
        "HTTP://LOCALHOST:3001"
    ])
    func acceptsSafeOrigins(origin: String) throws {
        let configuration = try APIConfiguration(origin: origin)
        let url = configuration.url(for: .verify)
        #expect(url.path == "/api/account/verify")
        #expect(url.query == nil)
        #expect(configuration.contains(url))
    }

    @Test(arguments: [
        "http://api.roomlings.example", "http://localhost.evil.example",
        "http://127.0.0.2", "http://0.0.0.0", "http://localhost.",
        "http://[2001:db8::1]", "https://user:password@api.roomlings.example",
        "https://@api.roomlings.example", "https://api.roomlings.example/api",
        "https://api.roomlings.example//", "https://api.roomlings.example/%2f",
        "https://api.roomlings.example?query=1", "https://api.roomlings.example?",
        "https://api.roomlings.example#fragment", "https://api.roomlings.example#",
        "file:///api/account", "/api/account", "https://", "",
        "https://api.roomlings.example:0", "https://api.roomlings.example:65536",
        "http://%6cocalhost", "https://api.roomlings.example\\@other.example",
        "https://bad host.example", " https://api.roomlings.example"
    ])
    func rejectsUnsafeOrigins(origin: String) {
        #expect(throws: AccountError.invalidOrigin) { try APIConfiguration(origin: origin) }
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan])
    func requiresFiniteTimeout(timeout: Double) {
        #expect(throws: AccountError.invalidTimeout) {
            try APIConfiguration(origin: "https://api.roomlings.example", requestTimeout: timeout)
        }
    }

    @Test
    func originBoundaryIncludesSchemeHostAndEffectivePort() throws {
        let configuration = Fixtures.configuration
        #expect(configuration.contains(URL(string: "https://API.ROOMLINGS.EXAMPLE:443/api/account")!))
        for url in [
            "http://api.roomlings.example/api/account",
            "https://api.roomlings.example:8443/api/account",
            "https://other.example/api/account",
            "https://user@api.roomlings.example/api/account"
        ] {
            #expect(!configuration.contains(URL(string: url)!))
        }
    }

    @Test
    func sessionHasNoCookiesCredentialsOrCache() {
        let configuration = URLSessionTransport.sessionConfiguration(Fixtures.configuration)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 12)
        #expect(configuration.timeoutIntervalForResource == 12)
        #expect(!configuration.waitsForConnectivity)
    }

    @Test
    func codeRequestUsesNativeHeadersAndNormalizedBody() async throws {
        let transport = TestTransport(response: try Fixtures.response(["sent": .bool(true)]))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.sendEmailCode(email: " ROOMMATE@EXAMPLE.COM \n")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.roomlings.example/api/account/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 12)
        for header in ["Cookie", "Origin", "Sec-Fetch-Site", "X-CSRF-Token", "X-Roomlings-Request"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object(["email": .string("roommate@example.com")]))
        #expect(await session.state == nil)
        #expect(await store.readAttempts == 0)
    }

    @Test(arguments: ["/api/account", "https://other.example/api/account"])
    func redirectDelegateRejectsEvenSameOriginRedirects(destination: String) async throws {
        let session = URLSession(configuration: URLSessionTransport.sessionConfiguration(Fixtures.configuration))
        defer { session.invalidateAndCancel() }
        let original = Fixtures.configuration.url(for: .verify)
        let next = try #require(URL(string: destination, relativeTo: Fixtures.configuration.origin)?.absoluteURL)
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil))
        let result: URLRequest? = await withCheckedContinuation { continuation in
            RejectRedirects().urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: next)
            ) { continuation.resume(returning: $0) }
        }
        #expect(result == nil)
    }

    @Test
    func refusesRedirectResponsesWithoutRetrying() async throws {
        let transport = TestTransport(response: try Fixtures.failure(status: 307, code: nil))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(), transport: transport
        )
        await #expect(throws: AccountError.redirectRejected) {
            try await session.sendEmailCode(email: "roommate@example.com")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func rejectsInjectedCrossOriginResponsesBeforeConsumingToken() async throws {
        let response = HTTPResponse(
            data: try Fixtures.data(Fixtures.state(token: Fixtures.newToken)),
            statusCode: 200, url: URL(string: "https://other.example/api/account/verify")!
        )
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: store, transport: TestTransport(response: response)
        )
        await #expect(throws: AccountError.untrustedResponse) {
            try await session.verifyEmailCode(
                email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone"
            )
        }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
    }

    @Test(arguments: [
        ["sent": JSONValue.bool(false)], ["sent": JSONValue.string("true")], [:]
    ])
    func codeSuccessMustHaveValidShape(object: [String: JSONValue]) async throws {
        let transport = TestTransport(response: try Fixtures.response(object))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(), transport: transport
        )
        await #expect(throws: AccountError.invalidResponse) {
            try await session.sendEmailCode(email: "roommate@example.com")
        }
    }

    @Test
    func failuresNeverRetainServerTextURLsOrUnderlyingDescriptions() async throws {
        let unknownCode = Fixtures.oldToken.value
        let transport = TestTransport(response: try Fixtures.failure(status: 500, code: unknownCode))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(), transport: transport
        )
        do {
            try await session.restore()
            Issue.record("Expected a server failure")
        } catch {
            #expect(error as? AccountError == .server(status: 500, code: nil))
            #expect(!String(reflecting: error).contains(unknownCode))
            #expect(!error.localizedDescription.contains(unknownCode))
        }

        let leakingTransport = TestTransport { _, _ in
            throw URLError(.timedOut, userInfo: [
                NSLocalizedDescriptionKey: Fixtures.oldToken.value,
                NSURLErrorFailingURLStringErrorKey: "https://example.invalid/\(Fixtures.oldToken.value)"
            ])
        }
        let offlineSession = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(), transport: leakingTransport
        )
        do {
            try await offlineSession.restore()
            Issue.record("Expected a network failure")
        } catch {
            #expect(error as? AccountError == .network(code: URLError.timedOut.rawValue))
            #expect(!String(reflecting: error).contains(unknownCode))
            #expect(!error.localizedDescription.contains(unknownCode))
        }
    }
}
