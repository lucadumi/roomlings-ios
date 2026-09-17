import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native chore undo", .timeLimit(.minutes(1)))
struct ChoreUndoTests {
    @Test
    func onlyTheCurrentRecordedTurnCanBeUndone() throws {
        let board = try HouseholdChores(household: ChoreFixtures.snapshot(ChoreFixtures.completedHousehold))
        let completion = try #require(board.history.first)
        #expect(board.canUndo(completion))
        #expect(!board.canUndo(try #require(board.history.last)))
        let scenarios: [[String: JSONValue]] = [
            ["version": .integer(6)], ["archived": .bool(true)], ["occurrence": .integer(3)]
        ]
        for changes in scenarios {
            let changed = try projection(changes: changes)
            #expect(!changed.canUndo(completion))
        }
        let undone = try HouseholdChores(household: ChoreFixtures.snapshot(ChoreFixtures.undoneHousehold))
        #expect(!undone.canUndo(completion))
        #expect(!undone.canUndo(try #require(undone.history.first)))
    }

    @Test(arguments: ["removed", "replaced"])
    func overwrittenHistoryCannotReuseAnOldCompletion(kind: String) throws {
        let household = ChoreFixtures.completedHousehold
        let board = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        let completion = try #require(board.history.first)
        let items = try #require(household["chores"]?["items"])
        var history = try #require(household["chores"]?["history"]?.arrayValue)
        if kind == "removed" {
            history.removeFirst()
        } else {
            history[0] = ChoreFixtures.replacing(history[0], with: ["title": .string("A replacement record")])
        }
        let replacement = ChoreFixtures.replacing(household, with: [
            "chores": .object(["items": items, "history": .array(history)])
        ])
        let refreshed = try HouseholdChores(household: ChoreFixtures.snapshot(replacement))
        #expect(!refreshed.canUndo(completion))
        #expect(board.canUndo(completion))
    }

    @Test(arguments: [false, true])
    func completedOneOffsAndStoredObjectChoresRemainUndoable(storedObject: Bool) throws {
        var household = ChoreFixtures.completedHousehold
        var items = try #require(household["chores"]?["items"]?.arrayValue)
        var history = try #require(household["chores"]?["history"]?.arrayValue)
        if storedObject {
            let fields: [String: JSONValue] = ["componentId": .string("saved-object"), "componentName": .string("Our sink")]
            items[0] = ChoreFixtures.replacing(items[0], with: fields)
            history[0] = ChoreFixtures.replacing(history[0], with: fields)
            household = ChoreFixtures.replacing(household, with: [
                "roomComponents": .array([
                    ChoreFixtures.component(kind: "sink", roomID: "kitchen", installed: false, slotID: "kitchen-sink")
                ])
            ])
        } else {
            items[0] = ChoreFixtures.replacing(items[0], with: ["dueDate": .null, "repeatDays": .null])
        }
        household = ChoreFixtures.replacing(household, with: [
            "chores": .object(["items": .array(items), "history": .array(history)])
        ])
        let board = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        #expect(board.isPaused(try #require(board.items.first)) == storedObject)
        #expect(board.canUndo(try #require(board.history.first)))
    }

    @Test
    func undoUsesNativeTransportAndPublishesOnlyTheServerResult() async throws {
        let transport = TestTransport(responses: [
            try initialResponse(), try Fixtures.response(["household": ChoreFixtures.undoneHousehold])
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        let result = try await undo(client)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/chores/completions/\(ChoreFixtures.latestCompletionID.uuidString.lowercased())/undo")
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
        #expect(!request.httpShouldHandleCookies)
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(payload == .object([
            "version": .integer(18), "mutationVersion": .integer(18), "choreVersion": .integer(5),
            "mutationId": ChoreFixtures.id(ChoreFixtures.undoMutationID)
        ]))
        #expect(result.session?.household.value == ChoreFixtures.undoneHousehold)
        #expect(result.account == original.account)
        #expect(result.memberships == original.memberships)
        #expect(original.session?.household.value == ChoreFixtures.completedHousehold)
        #expect(result.session?.household.value["futureServerData"]?["maximum"] == .integer(Int64.max))
        let receipts = try #require(result.session?.household.value["mutationReceipts"]?.arrayValue)
        #expect(receipts.map { $0["id"] } == [
            ChoreFixtures.id(ChoreFixtures.mutationID), ChoreFixtures.id(ChoreFixtures.undoMutationID)
        ])
        #expect(await client.state == result)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        let board = try HouseholdChores(household: #require(result.session?.household))
        #expect(board.items.first?.dueDate == "2026-09-15")
        #expect(board.items.first?.turn == 0)
        #expect(board.items.first?.occurrence == 1)
        #expect(board.items.first?.version == 6)
        #expect(board.history.first?.undoneBy == ChoreFixtures.memberID)
    }

    @Test(arguments: [
        (409, Optional<AccountServerCode>.none), (409, .some(.mutationTooOld)),
        (409, .some(.mutationIDConflict)), (409, .some(.mutationPayloadChanged)),
        (401, .some(.reauthenticationRequired)), (401, .none),
        (409, .some(.accountDeletionPending)), (503, .some(.accountDeletionPending)),
        (403, .none), (404, .none), (500, .none), (500, .some(.accountSessionRequired)), (429, .none)
    ])
    func failedUndoKeepsStateAndCredentials(failure: (Int, AccountServerCode?)) async throws {
        let transport = TestTransport(responses: [
            try initialResponse(), try Fixtures.failure(status: failure.0, code: failure.1?.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.server(status: failure.0, code: failure.1)) { try await undo(client) }
        #expect(await client.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func aLostUndoResponseCanBeRetriedAfterRefreshingTheUndoneState() async throws {
        let initial = try initialResponse()
        let refreshed = try Fixtures.response(ChoreFixtures.state(household: ChoreFixtures.undoneHousehold))
        let replay = try Fixtures.response(["household": ChoreFixtures.undoneHousehold, "replayed": .bool(true)])
        let transport = TestTransport { _, index in
            switch index {
            case 0: return initial
            case 1: throw URLError(.networkConnectionLost)
            case 2: return refreshed
            case 3: return replay
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = AccountSession(configuration: Fixtures.configuration,
                                    tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) { try await undo(client) }
        #expect(await client.state == original)
        let restored = try await client.restore()
        let replayed = try await undo(client)
        #expect(replayed == restored)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[1].httpBody == requests[3].httpBody)
        #expect(requests[1].url == requests[3].url)
    }

    @Test(arguments: ["edited", "archived", "completed"])
    func replayKeepsLaterServerChangesWithoutRestoringTheOldSchedule(kind: String) async throws {
        let latest = try householdAfterUndo(change: kind)
        let initial = try initialResponse()
        let refreshed = try Fixtures.response(ChoreFixtures.state(household: latest))
        let replay = try Fixtures.response(["household": latest, "replayed": .bool(true)])
        let transport = TestTransport { _, index in
            switch index {
            case 0: return initial
            case 1: throw URLError(.networkConnectionLost)
            case 2: return refreshed
            case 3: return replay
            default: throw TestFailure.unexpectedRequest
            }
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) { try await undo(client) }
        #expect(await client.state == original)
        let restored = try await client.restore()
        let result = try await undo(client)
        #expect(result == restored)
        #expect(result.session?.household.value == latest)
        #expect(await store.token == Fixtures.oldToken)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[1].httpBody == requests[3].httpBody)
        #expect(requests[1].url == requests[3].url)
        let board = try HouseholdChores(household: #require(result.session?.household))
        #expect(!board.canUndo(try #require(board.history.first)))
        #expect(board.canUndo(try #require(board.history.last)) == (kind == "completed"))
    }

    @Test(arguments: ["stale-household", "missing-completion", "overwritten-completion", "wrong-actor"])
    func invalidReplayCannotConfirmOrReplaceTheRefreshedHousehold(kind: String) async throws {
        let latest = try householdAfterUndo(change: "edited")
        var response = latest
        let items = try #require(response["chores"]?["items"])
        var history = try #require(response["chores"]?["history"]?.arrayValue)
        switch kind {
        case "stale-household": response = ChoreFixtures.replacing(response, with: ["version": .integer(19)])
        case "missing-completion": history.removeFirst()
        case "overwritten-completion": history[0] = ChoreFixtures.replacing(history[0], with: ["resultVersion": .integer(6)])
        default: history[0] = ChoreFixtures.replacing(history[0], with: ["undoneBy": ChoreFixtures.id(ChoreFixtures.roommateID)])
        }
        response = ChoreFixtures.replacing(response, with: [
            "chores": .object(["items": items, "history": .array(history)])
        ])
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state(household: latest)),
            try Fixtures.response(["household": response, "replayed": .bool(true)])
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.invalidResponse) { try await undo(client) }
        #expect(await client.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func anyActiveRoommateMayUndoAnotherRoommatesCompletion() async throws {
        var responses: [HTTPResponse] = []
        for household in [ChoreFixtures.completedHousehold, ChoreFixtures.undoneHousehold] {
            let items = try #require(household["chores"]?["items"])
            var history = try #require(household["chores"]?["history"]?.arrayValue)
            history[0] = ChoreFixtures.replacing(history[0], with: ["completedBy": ChoreFixtures.id(ChoreFixtures.roommateID)])
            let changed = ChoreFixtures.replacing(household, with: [
                "chores": .object(["items": items, "history": .array(history)])
            ])
            responses.append(try Fixtures.response(responses.isEmpty ? ChoreFixtures.state(household: changed) : ["household": changed]))
        }
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
                                    transport: TestTransport(responses: responses))
        try await client.restore()
        let result = try await undo(client)
        let board = try HouseholdChores(household: #require(result.session?.household))
        #expect(board.history.first?.completedBy == ChoreFixtures.roommateID)
        #expect(board.history.first?.undoneBy == ChoreFixtures.memberID)
    }

    @Test(arguments: [
        "not-undone", "wrong-date", "wrong-turn", "wrong-occurrence", "old-version", "skipped-version",
        "wrong-id", "older-completion-version", "newer-completion-version", "wrong-actor", "wrong-update-time", "archived"
    ])
    func invalidUndoSuccessCannotBePublished(kind: String) async throws {
        var household = ChoreFixtures.undoneHousehold
        var items = try #require(household["chores"]?["items"]?.arrayValue)
        var history = try #require(household["chores"]?["history"]?.arrayValue)
        switch kind {
        case "not-undone":
            household = ChoreFixtures.replacing(ChoreFixtures.completedHousehold, with: ["version": .integer(19)])
        case "wrong-date": items[0] = ChoreFixtures.replacing(items[0], with: ["dueDate": .string("2026-09-16")])
        case "wrong-turn": items[0] = ChoreFixtures.replacing(items[0], with: ["turn": .integer(2)])
        case "wrong-occurrence": items[0] = ChoreFixtures.replacing(items[0], with: ["occurrence": .integer(2)])
        case "old-version": items[0] = ChoreFixtures.replacing(items[0], with: ["version": .integer(5)])
        case "skipped-version": items[0] = ChoreFixtures.replacing(items[0], with: ["version": .integer(7)])
        case "older-completion-version": history[0] = ChoreFixtures.replacing(history[0], with: ["resultVersion": .integer(4)])
        case "newer-completion-version": history[0] = ChoreFixtures.replacing(history[0], with: ["resultVersion": .integer(6)])
        case "wrong-actor": history[0] = ChoreFixtures.replacing(history[0], with: ["undoneBy": ChoreFixtures.id(ChoreFixtures.roommateID)])
        case "wrong-update-time":
            items[0] = ChoreFixtures.replacing(items[0], with: ["updatedAt": .string("2026-09-15T12:02:00.000Z")])
        case "archived": items[0] = ChoreFixtures.replacing(items[0], with: ["archived": .bool(true)])
        default: history[0] = ChoreFixtures.replacing(history[0], with: ["id": ChoreFixtures.id(UUID())])
        }
        if kind != "not-undone" {
            household = ChoreFixtures.replacing(household, with: [
                "chores": .object(["items": .array(items), "history": .array(history)])
            ])
        }
        let transport = TestTransport(responses: [try initialResponse(), try Fixtures.response(["household": household])])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.invalidResponse) { try await undo(client) }
        #expect(await client.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await client.isBusy == false)
    }

    @Test
    func expiryStillClearsTheNativeCredential() async throws {
        let transport = TestTransport(responses: [
            try initialResponse(), try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await client.restore()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await undo(client) }
        #expect(await client.state == nil)
        #expect(await store.token == nil)
    }

    @Test(arguments: [false, true])
    func undoSharesTheAccountOperationGateAndHonorsCancellation(cancelled: Bool) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try initialResponse()
        let saved = try Fixtures.response(["household": ChoreFixtures.undoneHousehold])
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return saved
        }
        let client = AccountSession(configuration: Fixtures.configuration,
                                    tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
        let original = try await client.restore()
        let pending = Task { try await undo(client) }
        await started.wait()
        await #expect(throws: AccountError.operationInProgress) { try await client.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await client.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await client.selectHousehold(id: UUID()) }
        await #expect(throws: AccountError.operationInProgress) { try await undo(client) }
        for operation in ChoreOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(client) }
        }
        if cancelled { pending.cancel() }
        await finish.signal()
        if cancelled {
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(await client.state == original)
        } else {
            let result = try await pending.value
            #expect(await client.state == result)
        }
        #expect(await client.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: ["no-state", "wrong-household", "missing-token", "replaced-token", "inactive-member", "deleting"])
    func undoCannotBypassCurrentAccountAndHouseholdIdentity(kind: String) async throws {
        var household = ChoreFixtures.completedHousehold
        if kind == "inactive-member" {
            let members = ChoreFixtures.members.map { member in
                ChoreFixtures.replacing(member, with: ["inactive": .bool(member["id"] != ChoreFixtures.id(ChoreFixtures.roommateID))])
            }
            household = ChoreFixtures.replacing(household, with: ["members": .array(members)])
        }
        let state = kind == "deleting" ? Fixtures.state(deletionPending: true) : ChoreFixtures.state(household: household)
        let transport = TestTransport(response: try Fixtures.response(state))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        if kind != "no-state" { try await client.restore() }
        let original = await client.state
        if kind == "missing-token" { await store.replaceToken(nil) }
        if kind == "replaced-token" { await store.replaceToken(Fixtures.newToken) }
        let credential = await store.token
        let failure: AccountError = kind == "wrong-household" ? .householdSelectionChanged : .accountStateRequired
        await #expect(throws: failure) {
            try await client.undoChoreCompletion(
                id: ChoreFixtures.latestCompletionID, choreVersion: 5,
                householdID: kind == "wrong-household" ? UUID() : ChoreFixtures.householdID,
                version: 18, mutationID: ChoreFixtures.undoMutationID
            )
        }
        #expect(await client.state == original)
        #expect(await store.token == credential)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == (kind == "no-state" ? 0 : 1))
        #expect(await client.isBusy == false)
    }

    @Test(arguments: ["read", "clear"], [false, true])
    func credentialFailuresRemainExplicitWithoutChangingState(kind: String, keychain: Bool) async throws {
        let failure: any Error = keychain ? KeychainError.status(operation: kind == "read" ? .read : .clear, status: -25308)
            : SensitiveFailure(detail: Fixtures.oldToken.value)
        let transport = TestTransport(responses: [
            try initialResponse(), try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: kind == "clear" ? failure : nil)
        let client = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await client.restore()
        if kind == "read" { await store.setReadFailure(failure) }
        if keychain {
            await #expect(throws: KeychainError.status(operation: kind == "read" ? .read : .clear, status: -25308)) {
                try await undo(client)
            }
        } else {
            await #expect(throws: AccountError.credentialStorage) { try await undo(client) }
        }
        #expect(await client.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == (kind == "read" ? 0 : 1))
        #expect(await transport.requests.count == (kind == "read" ? 1 : 2))
        #expect(await client.isBusy == false)
    }

    @Test(arguments: [Int64(-1), ChoreValidation.maximumInteger, Int64.max])
    func invalidChoreVersionsNeverSend(version: Int64) async throws {
        let transport = TestTransport(responses: [try initialResponse()])
        let client = AccountSession(configuration: Fixtures.configuration,
                                    tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
        try await client.restore()
        await #expect(throws: AccountError.invalidInput(.choreVersion)) {
            try await client.undoChoreCompletion(id: ChoreFixtures.latestCompletionID, choreVersion: version,
                                                householdID: ChoreFixtures.householdID, version: 18,
                                                mutationID: ChoreFixtures.undoMutationID)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [Int64(-1), ChoreValidation.maximumInteger, Int64.max])
    func invalidHouseholdVersionsNeverSend(version: Int64) async throws {
        let transport = TestTransport(responses: [try initialResponse()])
        let client = AccountSession(configuration: Fixtures.configuration,
                                    tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
        let original = try await client.restore()
        await #expect(throws: AccountError.invalidInput(.version)) {
            try await client.undoChoreCompletion(id: ChoreFixtures.latestCompletionID, choreVersion: 5,
                                                householdID: ChoreFixtures.householdID, version: version,
                                                mutationID: ChoreFixtures.undoMutationID)
        }
        #expect(await client.state == original)
        #expect(await transport.requests.count == 1)
    }

    private func initialResponse() throws -> HTTPResponse {
        try Fixtures.response(ChoreFixtures.state(household: ChoreFixtures.completedHousehold))
    }

    private func undo(_ client: AccountSession) async throws -> AccountState {
        try await client.undoChoreCompletion(id: ChoreFixtures.latestCompletionID, choreVersion: 5,
                                            householdID: ChoreFixtures.householdID, version: 18,
                                            mutationID: ChoreFixtures.undoMutationID)
    }

    private func householdAfterUndo(change: String) throws -> JSONValue {
        let household = ChoreFixtures.undoneHousehold
        var items = try #require(household["chores"]?["items"]?.arrayValue)
        var history = try #require(household["chores"]?["history"]?.arrayValue)
        items[0] = ChoreFixtures.replacing(items[0], with: [
            "version": .integer(7), "updatedAt": .string("2026-09-24T12:00:00.000Z")
        ])
        switch change {
        case "edited":
            items[0] = ChoreFixtures.replacing(items[0], with: ["dueDate": .string("2026-09-30"), "turn": .integer(1)])
        case "archived":
            items[0] = ChoreFixtures.replacing(items[0], with: ["archived": .bool(true)])
        default:
            items[0] = ChoreFixtures.replacing(items[0], with: [
                "dueDate": .string("2026-09-29"), "turn": .integer(2), "occurrence": .integer(2)
            ])
            let completion = try #require(ChoreFixtures.completedHousehold["chores"]?["history"]?.arrayValue?.first)
            history.append(ChoreFixtures.replacing(completion, with: [
                "id": ChoreFixtures.id(ChoreFixtures.addedID), "resultVersion": .integer(7),
                "completedBy": ChoreFixtures.id(ChoreFixtures.roommateID),
                "completedAt": .string("2026-09-24T12:00:00.000Z")
            ]))
        }
        return ChoreFixtures.replacing(household, with: [
            "version": .integer(20), "chores": .object(["items": .array(items), "history": .array(history)])
        ])
    }

    private func projection(changes: [String: JSONValue]) throws -> HouseholdChores {
        let household = ChoreFixtures.completedHousehold
        let item = try #require(household["chores"]?["items"]?.arrayValue?.first)
        let history = try #require(household["chores"]?["history"])
        let changed = ChoreFixtures.replacing(household, with: [
            "chores": .object(["items": .array([ChoreFixtures.replacing(item, with: changes)]), "history": history])
        ])
        return try HouseholdChores(household: ChoreFixtures.snapshot(changed))
    }
}
