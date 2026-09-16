import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native chore mutations", .timeLimit(.minutes(1)))
struct ChoreSessionTests {
    @Test(arguments: ChoreOperation.allCases)
    func mutationsUseNativeTransportAndPreserveTheCompleteServerHousehold(operation: ChoreOperation) async throws {
        let household = operation.successHousehold
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.response(["household": household], path: String(operation.path.dropFirst()))
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let updated = try await operation.perform(session)
        let request = try #require(await transport.requests.last)
        expectNativeRequest(request, path: operation.path)
        var expected: [String: JSONValue] = [
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": ChoreFixtures.id(ChoreFixtures.mutationID)
        ]
        if operation == .add {
            expected.merge(ChoreFixtures.draft.requestFields) { _, new in new }
        } else {
            expected["choreVersion"] = .integer(4)
        }
        let payload = try body(request)
        #expect(payload == .object(expected))
        for key in ["householdId", "account", "accessToken", "csrfToken", "memberId", "completedBy", "session"] {
            #expect(payload[key] == nil)
        }
        #expect(updated.account == original.account)
        #expect(updated.memberships == original.memberships)
        #expect(updated.devices == original.devices)
        #expect(updated.configured == original.configured)
        #expect(updated.deletionPending == original.deletionPending)
        #expect(updated.session?.memberID == original.session?.memberID)
        #expect(updated.session?.household.value == household)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(updated))
        let originalEncoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
        #expect(encoded["csrfToken"] == originalEncoded["csrfToken"])
        #expect(encoded["session"]?["token"] == .null)
        #expect(encoded["session"]?["household"]?["futureServerData"]?["maximum"] == .integer(Int64.max))
        #expect(await session.state == updated)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func wholeHomeOneOffAddsExplicitNullsAndRequiresNoExtraFetch() async throws {
        let draft = try ChoreDraft(title: "Tidy up", dueDate: "1900-01-01", rotation: [ChoreFixtures.memberID])
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.response(["household": ChoreFixtures.addedHousehold(draft)])
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        try await session.addChore(
            draft, householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
        )
        let payload = try body(#require(await transport.requests.last))
        #expect(payload["roomId"] == .null)
        #expect(payload["area"] == .null)
        #expect(payload["componentId"] == .null)
        #expect(payload["repeatDays"] == .null)
        #expect(payload["notes"] == .string(""))
        #expect(payload["turn"] == .integer(0))
        #expect(await transport.requests.count == 2)
    }

    @Test
    func anyActiveRoommateCanCompleteAndOnlyTheServerAdvancesTheSchedule() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.response(["household": ChoreFixtures.completedHousehold])
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
            transport: transport
        )
        let original = try await session.restore()
        let before = try HouseholdChores(household: #require(original.session?.household))
        #expect(before.assignee(for: try #require(before.items.first))?.id == ChoreFixtures.roommateID)
        #expect(original.session?.memberID == ChoreFixtures.memberID)
        let updated = try await ChoreOperation.complete.perform(session)
        let after = try HouseholdChores(household: #require(updated.session?.household))
        #expect(after.items.first?.dueDate == "2026-09-22")
        #expect(after.items.first?.turn == 2)
        #expect(after.items.first?.occurrence == 2)
        #expect(after.history.first?.assignedTo == ChoreFixtures.roommateID)
        #expect(after.history.first?.completedBy == ChoreFixtures.memberID)
        #expect(before.items.first?.dueDate == "2026-09-15")
        #expect(before.items.first?.turn == 0)
    }

    @Test(arguments: ChoreOperation.allCases)
    func explicitRetryKeepsIdenticalBytesAndOriginalVersionsAfterLostResponseAndRestore(
        operation: ChoreOperation
    ) async throws {
        let initial = try Fixtures.response(ChoreFixtures.state())
        let refreshed = try Fixtures.response(ChoreFixtures.state(household: operation.successHousehold))
        let replayed = try Fixtures.response(["household": operation.successHousehold, "replayed": .bool(true)])
        let transport = TestTransport { _, index in
            switch index {
            case 0: return initial
            case 1: throw URLError(.networkConnectionLost)
            case 2: return refreshed
            case 3: return replayed
            default: throw TestFailure.unexpectedRequest
            }
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await operation.perform(session)
        }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 2)
        let refreshedState = try await session.restore()
        #expect(refreshedState.session?.household.version == 18)
        let retried = try await operation.perform(session)
        #expect(retried == refreshedState)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[1].httpBody == requests[3].httpBody)
        #expect(requests[1].url == requests[3].url)
        #expect(try body(requests[3])["version"] == .integer(17))
        #expect(try body(requests[3])["mutationVersion"] == .integer(17))
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: ChoreOperation.allCases, [
        (409, Optional<AccountServerCode>.none),
        (409, .some(.mutationIDConflict)), (409, .some(.mutationPayloadChanged)), (409, .some(.mutationTooOld)),
        (404, .none), (403, .none), (400, .none), (429, .none),
        (401, .some(.reauthenticationRequired)), (401, .none),
        (409, .some(.accountDeletionPending)), (503, .some(.accountDeletionPending)),
        (500, .some(.accountSessionRequired))
    ])
    func conflictsAndNonExpiryErrorsNeverChangeStateOrCredentials(
        operation: ChoreOperation, failure: (Int, AccountServerCode?)
    ) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.failure(status: failure.0, code: failure.1?.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let expected = AccountError.server(status: failure.0, code: failure.1)
        await #expect(throws: expected) { try await operation.perform(session) }
        #expect(!String(reflecting: expected).contains(Fixtures.oldToken.value))
        #expect(!expected.localizedDescription.contains("Sensitive server text"))
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func changedPayloadRetryRetainsItsIDAndSurfacesTheServerReplayConflict() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.response(["household": ChoreFixtures.addedHousehold()]),
            try Fixtures.failure(status: 409, code: "MUTATION_PAYLOAD_CHANGED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        let saved = try await ChoreOperation.add.perform(session)
        let changed = try ChoreDraft(title: "Different chore", dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID])
        await #expect(throws: AccountError.server(status: 409, code: .mutationPayloadChanged)) {
            try await session.addChore(
                changed, householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
            )
        }
        #expect(await session.state == saved)
        #expect(await store.token == Fixtures.oldToken)
        let requests = await transport.requests
        #expect(try body(requests[1])["mutationId"] == body(requests[2])["mutationId"])
        #expect(try body(requests[2])["mutationVersion"] == .integer(17))
        #expect(requests.count == 3)
    }

    @Test(arguments: ChoreOperation.allCases, ["network", "cancelled", "sensitive"])
    func transportFailuresAreSanitizedAndNeverRetried(operation: ChoreOperation, kind: String) async throws {
        let initial = try Fixtures.response(ChoreFixtures.state())
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            switch kind {
            case "network": throw URLError(.notConnectedToInternet)
            case "cancelled": throw URLError(.cancelled)
            default: throw SensitiveFailure(detail: Fixtures.oldToken.value)
            }
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        if kind == "cancelled" {
            await #expect(throws: CancellationError.self) { try await operation.perform(session) }
        } else {
            let expected = AccountError.network(code: kind == "network" ? URLError.notConnectedToInternet.rawValue : nil)
            await #expect(throws: expected) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ChoreOperation.allCases, [
        "wrong-household", "stale", "future-unreplayed", "missing-chores", "malformed-chores",
        "signed-out", "access-token", "replayed-false", "replayed-null", "inactive-member"
    ])
    func invalidSuccessesCannotBePublished(operation: ChoreOperation, kind: String) async throws {
        var household = operation.successHousehold
        var extra: [String: JSONValue] = [:]
        switch kind {
        case "wrong-household": household = ChoreFixtures.replacing(household, with: ["id": ChoreFixtures.id(UUID())])
        case "stale": household = ChoreFixtures.replacing(household, with: ["version": .integer(17)])
        case "future-unreplayed": household = ChoreFixtures.replacing(household, with: ["version": .integer(19)])
        case "missing-chores": household = ChoreFixtures.removing("chores", from: household)
        case "malformed-chores": household = ChoreFixtures.replacing(household, with: [
            "chores": .object(["items": .array([.null]), "history": .array([])])
        ])
        case "access-token": extra["accessToken"] = .string(Fixtures.newToken.value)
        case "replayed-false": extra["replayed"] = .bool(false)
        case "replayed-null": extra["replayed"] = .null
        case "inactive-member":
            let members = ChoreFixtures.members.map { member in
                member["id"] == ChoreFixtures.id(ChoreFixtures.memberID)
                    ? ChoreFixtures.replacing(member, with: ["inactive": .bool(true)]) : member
            }
            household = ChoreFixtures.replacing(household, with: ["members": .array(members)])
        default: break
        }
        var object = extra.merging(["household": household]) { _, new in new }
        if kind == "signed-out" { object = Fixtures.state(signedIn: false) }
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()), try Fixtures.response(object)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: ChoreOperation.allCases)
    func staleReplayCannotRollBackANewerRestoredHousehold(operation: ChoreOperation) async throws {
        let latest = ChoreFixtures.replacing(operation.successHousehold, with: ["version": .integer(24)])
        let older = ChoreFixtures.replacing(operation.successHousehold, with: ["version": .integer(23)])
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state(household: latest)),
            try Fixtures.response(["household": older, "replayed": .bool(true)])
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
    }

    @Test(arguments: ChoreOperation.allCases)
    func replayCanReturnTheLatestHouseholdBeyondTheOriginalMutation(operation: ChoreOperation) async throws {
        let latest = ChoreFixtures.replacing(operation.successHousehold, with: ["version": .integer(24)])
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.response(["household": latest, "replayed": .bool(true)])
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        let updated = try await operation.perform(session)
        #expect(updated.session?.household.version == 24)
        #expect(updated.session?.household.value == latest)
        #expect(await store.token == Fixtures.oldToken)
    }

    @Test(arguments: ["missing", "unchanged", "skipped"])
    func completionRequiresTheTargetChoresResultingVersion(kind: String) async throws {
        let chore: JSONValue
        switch kind {
        case "unchanged": chore = ChoreFixtures.chore
        case "skipped": chore = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["version": .integer(6)])
        default: chore = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["id": ChoreFixtures.id(ChoreFixtures.addedID)])
        }
        let household = ChoreFixtures.household(items: [chore], history: [], version: 18)
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()), try Fixtures.response(["household": household])
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
            transport: transport
        )
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await ChoreOperation.complete.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: ChoreOperation.allCases, ["no-state", "signed-out", "unselected", "deleting", "inactive"])
    func requiresARestoredNativeAccountWithAnActiveSelectedHousehold(operation: ChoreOperation, kind: String) async throws {
        let object: [String: JSONValue]
        switch kind {
        case "signed-out": object = Fixtures.state(signedIn: false)
        case "unselected": object = Fixtures.state()
        case "deleting": object = Fixtures.state(deletionPending: true)
        case "inactive":
            let members = ChoreFixtures.members.map { member in
                ChoreFixtures.replacing(member, with: ["inactive": .bool(true)])
            }
            object = ChoreFixtures.state(household: ChoreFixtures.replacing(
                ChoreFixtures.household(), with: ["members": .array(members)]
            ))
        default: object = ChoreFixtures.state()
        }
        let transport = TestTransport(response: try Fixtures.response(object))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        if kind != "no-state" { try await session.restore() }
        let original = await session.state
        let token = await store.token
        let clearAttempts = await store.clearAttempts
        await #expect(throws: AccountError.accountStateRequired) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == token)
        #expect(await store.clearAttempts == clearAttempts)
        #expect(await transport.requests.count == (kind == "no-state" ? 0 : 1))
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ChoreOperation.allCases)
    func callerMustNameTheCurrentlySelectedHousehold(operation: ChoreOperation) async throws {
        let transport = TestTransport(response: try Fixtures.response(ChoreFixtures.state()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.householdSelectionChanged) {
            try await operation.perform(session, householdID: UUID())
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ChoreOperation.allCases, [false, true])
    func stateCannotBeUsedWithAMissingOrReplacedNativeToken(operation: ChoreOperation, missing: Bool) async throws {
        let transport = TestTransport(response: try Fixtures.response(ChoreFixtures.state()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let replacement = missing ? nil : Fixtures.newToken
        await store.replaceToken(replacement)
        await #expect(throws: AccountError.accountStateRequired) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == replacement)
        #expect(await transport.requests.count == 1)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: ChoreOperation.allCases, [Int64(-1), ChoreValidation.maximumInteger, Int64.max])
    func rejectsInvalidHouseholdVersionsWithoutSending(operation: ChoreOperation, version: Int64) async throws {
        let transport = TestTransport(response: try Fixtures.response(ChoreFixtures.state()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidInput(.version)) { try await operation.perform(session, version: version) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [Int64(-1), ChoreValidation.maximumInteger, Int64.max])
    func rejectsInvalidChoreVersionsWithoutSending(version: Int64) async throws {
        let transport = TestTransport(response: try Fixtures.response(ChoreFixtures.state()))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
            transport: transport
        )
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidInput(.choreVersion)) {
            try await session.completeChore(
                id: ChoreFixtures.choreID, choreVersion: version,
                householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
            )
        }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ChoreOperation.allCases)
    func confirmedExpiryClearsStateAndCredentials(operation: ChoreOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) {
            try await operation.perform(session)
        }
        #expect(await session.state == nil)
        #expect(await session.selectedHousehold == nil)
        #expect(await store.token == nil)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 1)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ChoreOperation.allCases, [false, true])
    func failedExpiryStorageIsExplicitAndCannotPublishSignedOutState(operation: ChoreOperation, keychain: Bool) async throws {
        let failure: any Error = keychain ? KeychainError.status(operation: .clear, status: -25308)
            : SensitiveFailure(detail: Fixtures.oldToken.value)
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: failure)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        if keychain {
            await #expect(throws: KeychainError.status(operation: .clear, status: -25308)) {
                try await operation.perform(session)
            }
        } else {
            await #expect(throws: AccountError.credentialStorage) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 1)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ChoreOperation.allCases, [false, true])
    func credentialReadFailurePreventsTheMutation(operation: ChoreOperation, keychain: Bool) async throws {
        let transport = TestTransport(response: try Fixtures.response(ChoreFixtures.state()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let failure: any Error = keychain ? KeychainError.status(operation: .read, status: -25308)
            : SensitiveFailure(detail: Fixtures.oldToken.value)
        await store.setReadFailure(failure)
        if keychain {
            await #expect(throws: KeychainError.status(operation: .read, status: -25308)) {
                try await operation.perform(session)
            }
        } else {
            await #expect(throws: AccountError.credentialStorage) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 1)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ChoreOperation.allCases)
    func choreMutationsSerializeWithEveryAccountAndHouseholdOperation(operation: ChoreOperation) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(ChoreFixtures.state())
        let success = try Fixtures.response(["household": operation.successHousehold])
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return success
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let pending = Task { try await operation.perform(session) }
        await started.wait()
        #expect(await session.isBusy)
        #expect(await session.state == original)
        for operation in ChoreOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await session.selectHousehold(id: UUID()) }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.verifyEmailCode(email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone")
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.recover(email: "roommate@example.com", recoveryCode: Fixtures.recoveryCode, deviceLabel: "iPhone")
        }
        await finish.signal()
        let updated = try await pending.value
        #expect(await session.state == updated)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func choresCannotRacePendingSignInCredentialPersistence() async throws {
        let started = Signal()
        let finish = Signal()
        var signedIn = ChoreFixtures.state()
        signedIn["accessToken"] = .string(Fixtures.newToken.value)
        let transport = TestTransport(response: try Fixtures.response(signedIn))
        let store = MemoryTokenStore(token: Fixtures.oldToken, saveStarted: started, finishSave: finish)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let signIn = Task {
            try await session.verifyEmailCode(email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone")
        }
        await started.wait()
        for operation in ChoreOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        #expect(await session.state == nil)
        await finish.signal()
        _ = try await signIn.value
        #expect(await store.token == Fixtures.newToken)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func confirmedExpiryKeepsTheGateUntilCredentialClearingCompletes() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state()),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearStarted: started, finishClear: finish)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let pending = Task { try await ChoreOperation.add.perform(session) }
        await started.wait()
        #expect(await session.state == original)
        #expect(await session.isBusy)
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        for operation in ChoreOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await finish.signal()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await pending.value }
        #expect(await session.state == nil)
        #expect(await store.token == nil)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func cancellationAfterSendingDoesNotPublishALateSuccess() async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(ChoreFixtures.state())
        let success = try Fixtures.response(["household": ChoreFixtures.addedHousehold()])
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return success
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let pending = Task { try await ChoreOperation.add.perform(session) }
        await started.wait()
        pending.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    private func expectNativeRequest(_ request: URLRequest, path: String) {
        #expect(request.url?.path == path)
        #expect(request.url?.host == Fixtures.configuration.origin.host)
        #expect(request.url?.query == nil)
        #expect(request.url?.fragment == nil)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == Fixtures.configuration.requestTimeout)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(!request.httpShouldHandleCookies)
        for header in ["Cookie", "Origin", "X-CSRF-Token", "X-Roomlings-Request", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }
}
