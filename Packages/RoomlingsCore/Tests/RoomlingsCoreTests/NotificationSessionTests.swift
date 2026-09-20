import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native notification account coordination", .timeLimit(.minutes(1)))
struct NotificationSessionTests {
    @Test(arguments: NotificationOperation.allCases)
    func usesAuthenticatedNativeRoutesWithoutChangingLedgerState(operation: NotificationOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try operation.response()
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let result = try await operation.perform(session)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == operation.method)
        #expect(request.url?.path == operation.path)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)"
        #expect(authenticated)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == Fixtures.configuration.requestTimeout)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        switch operation {
        case .load, .unregister:
            #expect(request.httpBody == nil)
        case .save:
            let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
            #expect(body == .object(["chores": .bool(true), "money": .bool(false)]))
        case .register:
            let body = try HouseholdFields(JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)))
            #expect(Set(body.object.keys) == ["installationId", "token", "environment"])
            #expect(try body.uuid("installationId") == NotificationFixtures.installationID)
            #expect(try body.string("environment") == "sandbox")
            let matchesDeviceToken = try body.string("token") == NotificationFixtures.deviceToken.value
            #expect(matchesDeviceToken)
            #expect(request.url?.absoluteString.contains(NotificationFixtures.deviceToken.value) == false)
        }
        if let result {
            #expect(result.householdID == NotificationFixtures.householdID)
            #expect(result.memberID == NotificationFixtures.memberID)
            #expect(result.preferences == NotificationFixtures.preferences)
        }
        #expect(await session.state == original)
        #expect(await session.selectedHousehold?.version == 17)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test
    func registrationUsesTheExplicitProductionEnvironment() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try NotificationOperation.register.response()
        ])
        let session = makeSession(transport)
        try await session.restore()
        try await session.registerPushDevice(
            installationID: NotificationFixtures.installationID,
            token: NotificationFixtures.deviceToken, environment: .production
        )
        let request = try #require(await transport.requests.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body["environment"] == .string("production"))
    }

    @Test(arguments: NotificationOperation.devices, ["unselected", "inactive"])
    func deviceRegistrationRequiresAnAccountButNotHouseholdAccess(operation: NotificationOperation, kind: String) async throws {
        let initial = kind == "inactive" ? try NotificationFixtures.inactiveState() : Fixtures.state()
        let transport = TestTransport(responses: [try Fixtures.response(initial), try operation.response()])
        let session = makeSession(transport)
        let original = try await session.restore()
        try await operation.perform(session)
        #expect(await session.state == original)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: NotificationOperation.allCases, ["unrestored", "signed-out", "deleting"])
    func everyOperationRequiresAConfirmedNativeAccount(operation: NotificationOperation, kind: String) async throws {
        let initial = Fixtures.state(signedIn: kind != "signed-out", deletionPending: kind == "deleting")
        let transport = TestTransport(response: try Fixtures.response(initial))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        if kind != "unrestored" { try await session.restore() }
        let original = await session.state
        let credential = await store.token
        await #expect(throws: AccountError.accountStateRequired) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == credential)
        #expect(await transport.requests.count == (kind == "unrestored" ? 0 : 1))
        #expect(await session.isBusy == false)
    }

    @Test(arguments: NotificationOperation.settings, ["unselected", "inactive"])
    func preferencesRequireAnActiveSelectedMember(operation: NotificationOperation, kind: String) async throws {
        let initial = kind == "inactive" ? try NotificationFixtures.inactiveState() : Fixtures.state()
        let transport = TestTransport(response: try Fixtures.response(initial))
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.accountStateRequired) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: NotificationOperation.settings)
    func anotherHouseholdCannotBeReadOrChanged(operation: NotificationOperation) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.householdSelectionChanged) {
            try await operation.perform(session, householdID: UUID())
        }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: NotificationOperation.allCases, ["missing", "replaced"])
    func lostCredentialsNeverFallBackToAnonymousRequests(operation: NotificationOperation, kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let replacement = kind == "missing" ? nil : Fixtures.newToken
        await store.replaceToken(replacement)
        await #expect(throws: AccountError.accountStateRequired) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == replacement)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: NotificationOperation.allCases, ["keychain", "unknown", "cancelled"])
    func failedCredentialReadsAreExplicitAndSanitized(operation: NotificationOperation, kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        switch kind {
        case "keychain":
            await store.setReadFailure(KeychainError.status(operation: .read, status: -25308))
            await #expect(throws: KeychainError.status(operation: .read, status: -25308)) { try await operation.perform(session) }
        case "cancelled":
            await store.setReadFailure(CancellationError())
            await #expect(throws: CancellationError.self) { try await operation.perform(session) }
        default:
            await store.setReadFailure(SensitiveFailure(detail: Fixtures.oldToken.value))
            await #expect(throws: AccountError.credentialStorage) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await transport.requests.count == 1)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: NotificationOperation.settings, ["household", "member", "missing-availability", "credential", "nested-credential"])
    func untrustedSettingsCannotPublishSuccessOrReplaceGoodAccountState(operation: NotificationOperation, fault: String) async throws {
        var fields = NotificationFixtures.settings()
        switch fault {
        case "household": fields["householdId"] = .string(Fixtures.deviceID)
        case "member": fields["memberId"] = .string(Fixtures.deviceID)
        case "missing-availability": fields.removeValue(forKey: "pushAvailable")
        case "credential": fields["accessToken"] = .string(Fixtures.newToken.value)
        default:
            fields["preferences"] = .object([
                "chores": .bool(true), "money": .bool(false), "credential": .string(Fixtures.newToken.value)
            ])
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(fields)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func savedSettingsMustConfirmTheRequestedPreferences() async throws {
        var fields = NotificationFixtures.settings()
        fields["preferences"] = .object(["chores": .bool(false), "money": .bool(false)])
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(fields)
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await NotificationOperation.save.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: NotificationOperation.settings)
    func preferencesCanBeSavedAndLoadedWithoutConfiguredAPNs(operation: NotificationOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(NotificationFixtures.settings(pushAvailable: false))
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        let result = try #require(await operation.perform(session))
        #expect(result.pushAvailable == false)
        #expect(result.preferences == NotificationFixtures.preferences)
        #expect(await session.state == original)
    }

    @Test(arguments: NotificationOperation.devices, ["false", "missing", "null", "integer", "string", "accessToken", "credential", "token"])
    func deviceResponsesRequireOnlyATrueAcknowledgment(operation: NotificationOperation, fault: String) async throws {
        var fields: [String: JSONValue] = [operation.acknowledgment: .bool(true)]
        switch fault {
        case "false": fields[operation.acknowledgment] = .bool(false)
        case "missing": fields.removeValue(forKey: operation.acknowledgment)
        case "null": fields[operation.acknowledgment] = .null
        case "integer": fields[operation.acknowledgment] = .integer(1)
        case "string": fields[operation.acknowledgment] = .string("true")
        default: fields[fault] = .string(Fixtures.newToken.value)
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()), try Fixtures.response(fields)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: NotificationOperation.allCases, ["success", "keychain", "unknown"])
    func confirmedExpiryClearsAccessOnlyAfterCredentialRemoval(operation: NotificationOperation, kind: String) async throws {
        let failure: (any Error)?
        switch kind {
        case "keychain": failure = KeychainError.status(operation: .clear, status: -25308)
        case "unknown": failure = SensitiveFailure(detail: Fixtures.oldToken.value)
        default: failure = nil
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: failure)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        if kind == "keychain" {
            await #expect(throws: KeychainError.status(operation: .clear, status: -25308)) { try await operation.perform(session) }
        } else {
            let expected: AccountError = kind == "unknown" ? .credentialStorage : .server(status: 401, code: .accountSessionRequired)
            await #expect(throws: expected) { try await operation.perform(session) }
        }
        #expect(await store.clearAttempts == 1)
        #expect(await store.saveAttempts == 0)
        #expect(await store.token == (kind == "success" ? nil : Fixtures.oldToken))
        #expect(await session.state == (kind == "success" ? nil : original))
        #expect(await session.isBusy == false)
    }

    @Test(arguments: NotificationOperation.allCases, ["unauthorized", "reauthentication", "membership", "conflict", "rate-limit", "push-provider", "deleting"])
    func otherServerFailuresNeverEraseCredentialsOrExposeUpstreamText(operation: NotificationOperation, kind: String) async throws {
        let status: Int
        let code: AccountServerCode?
        switch kind {
        case "unauthorized": (status, code) = (401, nil)
        case "reauthentication": (status, code) = (401, .reauthenticationRequired)
        case "membership": (status, code) = (403, nil)
        case "conflict": (status, code) = (409, nil)
        case "rate-limit": (status, code) = (429, nil)
        case "push-provider": (status, code) = (503, .pushNotConfigured)
        default: (status, code) = (503, .accountDeletionPending)
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: status, code: code?.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let expected = AccountError.server(status: status, code: code)
        await #expect(throws: expected) { try await operation.perform(session) }
        #expect(!expected.localizedDescription.contains(Fixtures.oldToken.value))
        #expect(!expected.localizedDescription.contains("Sensitive server text"))
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: NotificationOperation.allCases, ["lost-response", "unknown", "cancelled"])
    func transportFailuresAreSanitizedAndNeverAutomaticallyRetried(operation: NotificationOperation, kind: String) async throws {
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            switch kind {
            case "lost-response": throw URLError(.networkConnectionLost)
            case "cancelled": throw URLError(.cancelled)
            default: throw SensitiveFailure(detail: NotificationFixtures.deviceToken.value)
            }
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        if kind == "cancelled" {
            await #expect(throws: CancellationError.self) { try await operation.perform(session) }
        } else {
            let code = kind == "lost-response" ? URLError.networkConnectionLost.rawValue : nil
            await #expect(throws: AccountError.network(code: code)) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: NotificationOperation.allCases)
    func allNotificationsShareTheExistingAccountOperationGate(operation: NotificationOperation) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let success = try operation.response()
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return success
        }
        let session = makeSession(transport)
        let original = try await session.restore()
        let pending = Task { try await operation.perform(session) }
        await started.wait()
        #expect(await session.isBusy)
        for overlap in NotificationOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await overlap.perform(session) }
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await session.selectHousehold(id: UUID()) }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.loadInvitations(householdID: NotificationFixtures.householdID)
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.completeChore(
                id: UUID(), choreVersion: 0, householdID: NotificationFixtures.householdID, version: 17, mutationID: UUID()
            )
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.removeShoppingItem(
                id: UUID(), itemVersion: 0, householdID: NotificationFixtures.householdID, version: 17, mutationID: UUID()
            )
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.removeExpense(id: UUID(), householdID: NotificationFixtures.householdID, version: 17, mutationID: UUID())
        }
        #expect(await session.state == original)
        await finish.signal()
        _ = try await pending.value
        #expect(await session.state == original)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func pendingCredentialPersistenceAlsoBlocksNotificationRequests() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(token: Fixtures.newToken, selectedHousehold: true)))
        let store = MemoryTokenStore(token: Fixtures.oldToken, saveStarted: started, finishSave: finish)
        let session = makeSession(transport, store)
        let pending = Task {
            try await session.verifyEmailCode(email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone")
        }
        await started.wait()
        for operation in NotificationOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await finish.signal()
        _ = try await pending.value
        #expect(await store.token == Fixtures.newToken)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func confirmedExpiryRetainsTheGateUntilTheClearFinishes() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearStarted: started, finishClear: finish)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let pending = Task { try await NotificationOperation.register.perform(session) }
        await started.wait()
        #expect(await session.isBusy)
        #expect(await session.state == original)
        for operation in NotificationOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await finish.signal()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await pending.value }
        #expect(await session.state == nil)
        #expect(await store.token == nil)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: NotificationOperation.allCases)
    func cancellationCannotReturnALateSuccessfulResponse(operation: NotificationOperation) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let success = try operation.response()
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return success
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let pending = Task { try await operation.perform(session) }
        await started.wait()
        pending.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: NotificationOperation.allCases, ["lost", "replaced", "expiry-lost", "expiry-replaced", "read-failed"])
    func inFlightCredentialChangesCannotConfirmSuccessOrEraseANewerCredential(operation: NotificationOperation, kind: String) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let response = kind.hasPrefix("expiry")
            ? try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED") : try operation.response()
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return response
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, store)
        let original = try await session.restore()
        let pending = Task { try await operation.perform(session) }
        await started.wait()
        let replacement = kind.hasSuffix("lost") ? nil : Fixtures.newToken
        if kind == "read-failed" {
            await store.setReadFailure(SensitiveFailure(detail: Fixtures.oldToken.value))
        } else {
            await store.replaceToken(replacement)
        }
        await finish.signal()
        let expected: AccountError = kind == "read-failed" ? .credentialStorage : .accountStateRequired
        await #expect(throws: expected) { try await pending.value }
        #expect(await session.state == original)
        #expect(await store.token == (kind == "read-failed" ? Fixtures.oldToken : replacement))
        #expect(await store.clearAttempts == 0)
        #expect(await store.saveAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    private func makeSession(_ transport: TestTransport, _ store: MemoryTokenStore? = nil) -> AccountSession {
        AccountSession(
            configuration: Fixtures.configuration,
            tokenStore: store ?? MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
    }
}
