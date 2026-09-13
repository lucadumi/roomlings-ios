import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native account sessions", .timeLimit(.minutes(1)))
struct SessionTests {
    @Test
    func verifiesAndPersistsRotationUsingTheExistingDeviceBearer() async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let state = try await session.verifyEmailCode(
            email: " ROOMMATE@EXAMPLE.COM ", code: " 12345678\n", name: " Roommate ", deviceLabel: " iPad "
        )
        #expect(state.isSignedIn)
        #expect(await session.state == state)
        #expect(await store.token == Fixtures.newToken)
        #expect(await store.saveAttempts == 1)
        #expect(await store.clearAttempts == 0)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/account/verify")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(!request.httpShouldHandleCookies)
        for header in ["Cookie", "Origin", "Sec-Fetch-Site", "X-CSRF-Token"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "email": .string("roommate@example.com"), "code": .string("12345678"),
            "name": .string("Roommate"), "label": .string("iPad")
        ]))
        #expect(await transport.requests.count == 1)
    }

    @Test
    func recoversWithAccountCodeAndRotatesCurrentBearer() async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.recover(
            email: " ROOMMATE@EXAMPLE.COM ", recoveryCode: " \(Fixtures.recoveryCode.uppercased()) ", deviceLabel: "iPhone"
        )
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/account/recover")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "email": .string("roommate@example.com"), "code": .string(Fixtures.recoveryCode), "label": .string("iPhone")
        ]))
        #expect(await store.token == Fixtures.newToken)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func freshSignInDoesNotInventAnAuthorizationHeader() async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let store = MemoryTokenStore()
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await verify(session)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await store.token == Fixtures.newToken)
    }

    @Test
    func restoreReusesBearerWithoutReSavingAndExposesSelectedHousehold() async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let state = try await session.restore()
        #expect(state.isSignedIn)
        #expect(await session.selectedHousehold?.id == UUID(uuidString: Fixtures.householdID))
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/account")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
    }

    @Test
    func signedOutRestoreConfirmsExpiryBeforeClearing() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        #expect(await store.token != nil)
        let expired = try await session.restore()
        #expect(!expired.isSignedIn)
        #expect(await session.state == expired)
        #expect(await session.selectedHousehold == nil)
        #expect(await store.token == nil)
        #expect(await store.clearAttempts == 1)
    }

    @Test
    func emptyKeychainStillReadsActualServerConfiguration() async throws {
        var object = Fixtures.state(signedIn: false)
        object["configured"] = .bool(false)
        let transport = TestTransport(response: try Fixtures.response(object))
        let store = MemoryTokenStore()
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        #expect(await session.state == nil)
        let state = try await session.restore()
        #expect(!state.configured)
        #expect(!state.isSignedIn)
        #expect(await transport.requests.count == 1)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func cannotRestoreASignedInStateWithoutABearer() async throws {
        let store = MemoryTokenStore()
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state()))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidResponse) { try await session.restore() }
        #expect(await session.state == nil)
        #expect(await store.token == nil)
    }

    @Test
    func deletionOnlyRestoreRetainsItsCredential() async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(deletionPending: true)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let state = try await session.restore()
        #expect(state.deletionPending)
        #expect(state.session == nil)
        #expect(state.memberships.isEmpty)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: [
        (401, AccountServerCode.reauthenticationRequired),
        (503, AccountServerCode.accountDeletionPending),
        (409, AccountServerCode.accountDeletionPending),
        (503, AccountServerCode.authProviderUnavailable),
        (500, AccountServerCode.accountSessionRequired)
    ], [false, true])
    func nonExpiryFailuresNeverEraseCredentials(
        failure: (Int, AccountServerCode), logout: Bool
    ) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()),
            try Fixtures.failure(status: failure.0, code: failure.1.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.server(status: failure.0, code: failure.1)) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await session.state == previous)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func onlyExplicitSessionRequired401ConfirmsExpiry(logout: Bool) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()),
            try Fixtures.failure(status: 401, code: AccountServerCode.accountSessionRequired.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await store.token == nil)
        #expect(await store.clearAttempts == 1)
        #expect(await session.state == nil)
    }

    @Test(arguments: [401, 403, 409, 429, 500, 503])
    func uncodedHTTPErrorsAreNotExpiry(status: Int) async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport(response: try Fixtures.failure(status: status, code: nil))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.server(status: status, code: nil)) { try await session.restore() }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: [false, true])
    func networkFailuresKeepTheLastConfirmedState(logout: Bool) async throws {
        let initial = try Fixtures.response(Fixtures.state())
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            throw URLError(.notConnectedToInternet)
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.notConnectedToInternet.rawValue)) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await session.state == previous)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func logoutClearsOnlyAfterValidConfirmedSignOut(allDevices: Bool) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        let state = try await session.logout(allDevices: allDevices)
        #expect(!state.isSignedIn)
        #expect(await session.state == state)
        #expect(await store.token == nil)
        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/api/account/logout")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object(["all": .bool(allDevices)]))
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func ordinaryAccountResponsesCannotReissueTokens(logout: Bool) async throws {
        let transport = TestTransport(response: try Fixtures.response(
            Fixtures.state(signedIn: !logout, token: Fixtures.newToken)
        ))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidResponse) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: [false, true])
    func malformedResponsesNeverSignOut(logout: Bool) async throws {
        let response = HTTPResponse(
            data: Data("{not-json:\(Fixtures.oldToken.value)}".utf8), statusCode: 200,
            url: Fixtures.configuration.url(for: .account)
        )
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: store, transport: TestTransport(response: response)
        )
        await #expect(throws: AccountError.invalidResponse) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: [false, true])
    func failedSignInOrRecoveryNeverRetriesOrErasesTheCurrentDevice(recovery: Bool) async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport { _, _ in throw URLError(.networkConnectionLost) }
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            if recovery {
                try await session.recover(
                    email: "roommate@example.com", recoveryCode: Fixtures.recoveryCode, deviceLabel: "iPhone"
                )
            } else {
                try await verify(session)
            }
        }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["missing", "malformed", "signedOut"])
    func signInRequiresNativeAccountStateAndNewBearer(scenario: String) async throws {
        var object = Fixtures.state(token: Fixtures.newToken)
        if scenario == "missing" { object.removeValue(forKey: "accessToken") }
        if scenario == "malformed" { object["accessToken"] = .string("provider-token-is-not-a-roomlings-session") }
        if scenario == "signedOut" { object = Fixtures.state(signedIn: false, token: Fixtures.newToken) }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport(response: try Fixtures.response(object))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidResponse) { try await verify(session) }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await session.state == nil)
    }

    @Test
    func invalidInputsDoNotSendRequestsOrChangeCredentials() async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidInput(.email)) {
            try await session.sendEmailCode(email: "invalid")
        }
        await #expect(throws: AccountError.invalidInput(.emailCode)) {
            try await session.verifyEmailCode(
                email: "roommate@example.com", code: "12345", name: "Roommate", deviceLabel: "iPhone"
            )
        }
        await #expect(throws: AccountError.invalidInput(.deviceLabel)) {
            try await session.verifyEmailCode(
                email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: " "
            )
        }
        await #expect(throws: AccountError.invalidInput(.recoveryCode)) {
            try await session.recover(
                email: "roommate@example.com", recoveryCode: "roomlings-kitchen-abcd-1234", deviceLabel: "iPhone"
            )
        }
        #expect(await transport.requests.isEmpty)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test
    func failedStorageDoesNotPublishSignInOrDeleteThePreviousCredential() async throws {
        let store = MemoryTokenStore(
            token: Fixtures.oldToken, saveFailure: SensitiveFailure(detail: Fixtures.newToken.value)
        )
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.credentialStorage) { try await verify(session) }
        #expect(await session.state == nil)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: [false, true])
    func failedCredentialClearIsNotPresentedAsSuccessfulLogoutOrExpiry(logout: Bool) async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: TestFailure.storage)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.credentialStorage) {
            if logout { try await session.logout() } else { try await session.restore() }
        }
        #expect(await session.state == previous)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 1)
    }

    @Test
    func storageReadFailuresDoNotBecomeSignedOutNetworkRequests() async throws {
        let store = MemoryTokenStore(readFailure: SensitiveFailure(detail: Fixtures.oldToken.value))
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(signedIn: false)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.credentialStorage) { try await session.restore() }
        #expect(await transport.requests.isEmpty)
        #expect(await session.state == nil)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func cancellationIsExplicitAndDoesNotEraseCredentials() async throws {
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport { _, _ in throw URLError(.cancelled) }
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: CancellationError.self) { try await session.restore() }
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test
    func signInIsNotPublishedUntilPersistenceAndOverlapsAreRejected() async throws {
        let started = Signal()
        let finish = Signal()
        let store = MemoryTokenStore(token: Fixtures.oldToken, saveStarted: started, finishSave: finish)
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken)))
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let signIn = Task { try await verify(session) }
        await started.wait()
        #expect(await session.state == nil)
        #expect(await session.isBusy)
        #expect(await store.token == Fixtures.oldToken)
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.recover(
                email: "roommate@example.com", recoveryCode: Fixtures.recoveryCode, deviceLabel: "iPhone"
            )
        }
        await finish.signal()
        try await signIn.value
        #expect(await session.state?.isSignedIn == true)
        #expect(await store.token == Fixtures.newToken)
        #expect(await store.saveAttempts == 1)
        #expect(await transport.requests.count == 1)
        #expect(await session.isBusy == false)
    }

    @Test
    func delayedRestoreCannotRaceAReplacementSession() async throws {
        let started = Signal()
        let finish = Signal()
        let signedOut = try Fixtures.response(Fixtures.state(signedIn: false))
        let signedIn = try Fixtures.response(Fixtures.state(token: Fixtures.newToken))
        let transport = TestTransport { _, index in
            if index == 0 {
                await started.signal()
                await finish.wait()
                return signedOut
            }
            return signedIn
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let restore = Task { try await session.restore() }
        await started.wait()
        await #expect(throws: AccountError.operationInProgress) { try await verify(session) }
        #expect(await store.token == Fixtures.oldToken)
        await finish.signal()
        let oldState = try await restore.value
        #expect(!oldState.isSignedIn)
        try await verify(session)
        #expect(await session.state?.isSignedIn == true)
        #expect(await store.token == Fixtures.newToken)
        #expect(await store.saveAttempts == 1)
        #expect(await store.clearAttempts == 1)
    }

    private func verify(_ session: AccountSession) async throws {
        try await session.verifyEmailCode(
            email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone"
        )
    }
}
