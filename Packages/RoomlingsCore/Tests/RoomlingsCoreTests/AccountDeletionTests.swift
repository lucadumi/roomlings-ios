import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native account deletion", .timeLimit(.minutes(1)))
struct AccountDeletionTests {
    private let accountID = UUID(uuidString: Fixtures.accountID)!
    private let email = "roommate@example.com"

    @Test(arguments: [false, true])
    func deletesOnlyTheConfirmedAccountWithNativeAuthentication(selected: Bool) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: selected)),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        try await session.restore()
        let result = try await session.deleteAccount(accountID: accountID, confirmation: email)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/account")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)"
        #expect(authenticated)
        #expect(!request.httpShouldHandleCookies)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(payload == .object(["confirmation": .string(email)]))
        #expect(!result.isSignedIn)
        #expect(await session.state == result)
        #expect(await session.deletionStatus == .completed)
        #expect(await session.selectedHousehold == nil)
        #expect(await credentials.token == nil)
        #expect(await credentials.clearAttempts == 1)
        #expect(await credentials.saveAttempts == 0)
    }

    @Test(arguments: ["", " roommate@example.com", "roommate@example.com ", "Roommate@example.com", "other@example.com"])
    func destructiveConfirmationIsNeverTrimmedOrNormalized(confirmation: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let session = make(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidInput(.confirmation)) {
            try await session.deleteAccount(accountID: accountID, confirmation: confirmation)
        }
        #expect(await transport.requests.count == 1)
        #expect(await session.state == original)
        #expect(await session.deletionStatus == .none)
    }

    @Test(arguments: ["unrestored", "signed-out", "other-account", "replaced-credential"])
    func staleFormsCannotDeleteAnotherAccount(kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(signedIn: kind != "signed-out")))
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        if kind != "unrestored" { try await session.restore() }
        if kind == "replaced-credential" { await credentials.replaceToken(Fixtures.newToken) }
        let expectedID = kind == "other-account" ? UUID() : accountID
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.deleteAccount(accountID: expectedID, confirmation: email)
        }
        #expect(await transport.requests.count == (kind == "unrestored" ? 0 : 1))
        #expect(await session.deletionStatus == .none)
    }

    @Test(arguments: [
        AccountError.server(status: 400, code: nil),
        .server(status: 401, code: .reauthenticationRequired),
        .server(status: 409, code: .ownershipTransferRequired),
        .server(status: 429, code: nil)
    ])
    func rejectedPreconditionsPreserveTheAccountAndDoNotRetry(error: AccountError) async throws {
        guard case .server(let status, let code) = error else {
            Issue.record("Expected a server failure fixture.")
            return
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: status, code: code?.rawValue)
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let original = try await session.restore()
        await #expect(throws: error) { try await session.deleteAccount(accountID: accountID, confirmation: email) }
        #expect(await session.state == original)
        #expect(await session.deletionStatus == .none)
        #expect(await session.selectedHousehold != nil)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func aProviderFailureBlocksHouseholdAccessUntilAnExplicitDeletionOnlyRetry() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: 503, code: "ACCOUNT_DELETION_PENDING"),
            try Fixtures.response(Fixtures.state(deletionPending: true)),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let original = try await session.restore()
        await #expect(throws: AccountError.server(status: 503, code: .accountDeletionPending)) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        #expect(await session.deletionStatus == .pending)
        #expect(await session.selectedHousehold == nil)
        #expect(await credentials.token == Fixtures.oldToken)
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.selectHousehold(id: UUID(uuidString: Fixtures.householdID)!)
        }
        let event = try AnalyticsEvent(kind: .appOpened, at: .now)
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.recordAnalytics(event, context: AnalyticsContext(state: original))
        }
        let pending = try await session.restore()
        #expect(pending.deletionPending)
        #expect(pending.memberships.isEmpty)
        #expect(pending.session == nil)
        let result = try await session.deleteAccount(accountID: accountID, confirmation: email)
        #expect(!result.isSignedIn)
        #expect(await session.deletionStatus == .completed)
        #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
    }

    @Test(arguments: ["network", "server", "malformed", "signed-in", "unexpected-token"])
    func uncertainDeletionNeedsARefreshRatherThanAnAutomaticOrBlindRetry(kind: String) async throws {
        let original = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let transport = TestTransport { request, _ in
            guard request.httpMethod == "DELETE" else { return original }
            switch kind {
            case "network": throw URLError(.networkConnectionLost)
            case "server": return try Fixtures.failure(status: 500, code: nil)
            case "signed-in": return original
            case "unexpected-token": return try Fixtures.response(Fixtures.state(signedIn: false, token: Fixtures.newToken))
            default: return try Fixtures.response(["deleted": .bool(true)])
            }
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let state = try await session.restore()
        await #expect(throws: AccountError.self) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        #expect(await session.deletionStatus == .unconfirmed)
        #expect(await session.selectedHousehold == nil)
        #expect(await credentials.clearAttempts == 0)
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        #expect(await transport.requests.count == 2)
        let refreshed = try await session.restore()
        #expect(refreshed == state)
        #expect(await session.deletionStatus == .none)
        #expect(await session.selectedHousehold != nil)
    }

    @Test
    func aSignedOutRefreshAfterAnUncertainRequestDoesNotClaimConfirmedDeletion() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.failure(status: 500, code: nil),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.self) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        let ended = try await session.restore()
        #expect(!ended.isSignedIn)
        #expect(await session.deletionStatus == .none)
    }

    @Test
    func endedCredentialsAreNotProofOfCompletedAccountDeletion() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED"),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        try await session.restore()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        #expect(await session.deletionStatus == .unconfirmed)
        #expect(await credentials.token == nil)
        try await session.restore()
        #expect(await session.deletionStatus == .none)
    }

    @Test
    func failedCredentialCleanupIsRetriedLocallyWithoutDeletingAgain() async throws {
        let credentials = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: TestFailure.storage)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let session = make(transport, credentials)
        try await session.restore()
        await #expect(throws: AccountError.credentialStorage) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        #expect(await session.deletionStatus == .localCleanupRequired)
        #expect(await session.state?.isSignedIn == false)
        #expect(await credentials.token == Fixtures.oldToken)
        await credentials.setDeletionClearFailure(nil)
        let result = try await session.finishAccountDeletionCleanup()
        #expect(!result.isSignedIn)
        #expect(await session.deletionStatus == .completed)
        #expect(await credentials.token == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func expiredAccessCannotForgetAnAlreadyAcknowledgedDeletion() async throws {
        let credentials = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: TestFailure.storage)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.response(Fixtures.state(signedIn: false)),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let session = make(transport, credentials)
        try await session.restore()
        await #expect(throws: AccountError.credentialStorage) {
            try await session.deleteAccount(accountID: accountID, confirmation: email)
        }
        await credentials.setDeletionClearFailure(nil)
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) {
            try await session.restore()
        }
        #expect(await session.deletionStatus == .completed)
        #expect(await credentials.token == nil)
        #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test
    func aLateDeletionResponseCannotEraseAReplacementCredential() async throws {
        let started = Signal()
        let finish = Signal()
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport { request, _ in
            if request.httpMethod == "DELETE" {
                await started.signal()
                await finish.wait()
                return try Fixtures.response(Fixtures.state(signedIn: false))
            }
            return try Fixtures.response(Fixtures.state())
        }
        let session = make(transport, credentials)
        try await session.restore()
        let pending = Task { try await session.deleteAccount(accountID: accountID, confirmation: email) }
        await started.wait()
        await credentials.replaceToken(Fixtures.newToken)
        await finish.signal()
        await #expect(throws: AccountError.accountStateRequired) { try await pending.value }
        #expect(await credentials.token == Fixtures.newToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await session.deletionStatus == .localCleanupRequired)
        await #expect(throws: AccountError.accountStateRequired) { try await session.finishAccountDeletionCleanup() }
        #expect(await credentials.clearAttempts == 0)
    }

    @Test
    func theAccountGateRemainsHeldUntilCredentialCleanupCompletes() async throws {
        let started = Signal()
        let finish = Signal()
        let credentials = MemoryTokenStore(token: Fixtures.oldToken, clearStarted: started, finishClear: finish)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let session = make(transport, credentials)
        try await session.restore()
        let pending = Task { try await session.deleteAccount(accountID: accountID, confirmation: email) }
        await started.wait()
        #expect(await session.isBusy)
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await finish.signal()
        try await pending.value
        #expect(await session.isBusy == false)
    }

    @Test
    func cancellationWithALateAcknowledgmentCannotPretendLocalCleanupFinished() async throws {
        let started = Signal()
        let finish = Signal()
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let transport = TestTransport { request, _ in
            if request.httpMethod == "DELETE" {
                await started.signal()
                await finish.wait()
                return try Fixtures.response(Fixtures.state(signedIn: false))
            }
            return try Fixtures.response(Fixtures.state())
        }
        let session = make(transport, credentials)
        try await session.restore()
        let pending = Task { try await session.deleteAccount(accountID: accountID, confirmation: email) }
        await started.wait()
        pending.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await session.deletionStatus == .localCleanupRequired)
        #expect(await credentials.clearAttempts == 0)
        try await session.finishAccountDeletionCleanup()
        #expect(await session.deletionStatus == .completed)
    }

    @Test
    func reauthenticationKeepsTheAccountAndUsesItsEmailRatherThanATypedIdentity() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(Fixtures.state(token: Fixtures.newToken, selectedHousehold: true))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        try await session.restore()
        let verified = try await session.reauthenticate(accountID: accountID, code: "123456", deviceLabel: "My phone")
        let request = try #require(await transport.requests.last)
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(request.url?.path == "/api/account/verify")
        #expect(payload["email"] == .string(email))
        #expect(payload["name"] == Fixtures.account["name"])
        #expect(payload["label"] == .string("My phone"))
        #expect(verified.account?.id == accountID)
        #expect(await credentials.token == Fixtures.newToken)
        #expect(await credentials.saveAttempts == 1)
        #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.isEmpty == true)
    }

    @Test
    func reauthenticationCannotAdoptAnotherAccountsResponse() async throws {
        var fields = Fixtures.state(token: Fixtures.newToken)
        var account = try HouseholdFields(Fixtures.account).object
        account["id"] = .string(UUID().uuidString)
        fields["account"] = .object(account)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.response(fields)
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) {
            try await session.reauthenticate(accountID: accountID, code: "123456", deviceLabel: "iPhone")
        }
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.state == original)
    }

    private func make(_ transport: TestTransport, _ credentials: MemoryTokenStore? = nil) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration,
                       tokenStore: credentials ?? MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}

extension MemoryTokenStore {
    func setDeletionClearFailure(_ failure: (any Error)?) { clearFailure = failure }
}
