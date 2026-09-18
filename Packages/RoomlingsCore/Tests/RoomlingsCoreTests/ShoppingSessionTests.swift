import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native shopping mutations", .timeLimit(.minutes(1)))
struct ShoppingSessionTests {
    @Test(arguments: ShoppingOperation.allCases)
    func everyRouteUsesTheSharedNativeTransportAndPublishesOnlyTheServerSnapshot(operation: ShoppingOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)),
            try Fixtures.response(["household": operation.successHousehold], path: String(operation.path.dropFirst()))
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let updated = try await operation.perform(session)
        let requests = await transport.requests
        let request = try #require(requests.last)
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.path == "/api/account")
        #expect(request.url?.path == operation.path)
        #expect(request.httpMethod == operation.method)
        #expect(request.url?.host == Fixtures.configuration.origin.host)
        #expect(request.url?.query == nil)
        #expect(request.url?.fragment == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 12)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        for header in ["Cookie", "Origin", "Sec-Fetch-Site", "X-CSRF-Token", "X-Roomlings-Request"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let expected = operation.fields.merging([
            "version": .integer(17), "mutationVersion": .integer(17), "mutationId": ShoppingFixtures.id(ShoppingFixtures.mutationID)
        ]) { _, new in new }
        #expect(try body(request) == .object(expected))
        for key in ["householdId", "memberId", "createdBy", "claimedBy", "session", "accessToken", "csrfToken", "componentSource", "amount"] {
            #expect(try body(request)[key] == nil)
        }
        #expect(updated.account == original.account)
        #expect(updated.memberships == original.memberships)
        #expect(updated.devices == original.devices)
        #expect(updated.configured == original.configured)
        #expect(updated.deletionPending == original.deletionPending)
        #expect(updated.session?.memberID == original.session?.memberID)
        #expect(updated.session?.household.value == operation.successHousehold)
        let household = try #require(updated.session?.household.value)
        for key in ["expenses", "settlements", "budget", "futureServerData"] {
            #expect(household[key] == operation.initialHousehold[key])
        }
        #expect(household["shopping"]?["runs"] == operation.initialHousehold["shopping"]?["runs"])
        #expect(household["shopping"]?["futureShoppingData"] == .integer(Int64.max))
        #expect(household["mutationReceipts"]?.arrayValue?.first?["futureReceiptData"] == .integer(Int64.max))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(updated))
        let initialEncoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
        #expect(encoded["csrfToken"] == initialEncoded["csrfToken"])
        #expect(encoded["session"]?["token"] == .null)
        #expect(await session.state == updated)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ShoppingOperation.allCases, [AccountRole.owner, .member])
    func householdRolesDoNotAddShoppingAssignmentRules(operation: ShoppingOperation, role: AccountRole) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold, role: role)),
            try Fixtures.response(["household": operation.successHousehold])
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        #expect(original.session?.memberID != ShoppingFixtures.roommateID)
        let result = try await operation.perform(session)
        #expect(result.session?.household.value == operation.successHousehold)
        if operation == .release {
            let item = try #require(result.session?.household.value["shopping"]?["items"]?.arrayValue?.first)
            #expect(item["claimedBy"] == .null)
            #expect(item["pickedUp"] == .bool(false))
        }
    }

    @Test
    func addingToALegacyHouseholdNeedsNoExtraListFetchAndAllowsDuplicateNames() async throws {
        let original = ShoppingFixtures.replacing(Fixtures.household, with: ["members": .array(ShoppingFixtures.members)])
        let added = try #require(ShoppingOperation.add.successHousehold["shopping"]?["items"]?.arrayValue?.last)
        let response = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(original, with: [
            "version": .integer(18), "shopping": .object(["items": .array([added]), "runs": .array([])])
        ]))
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: original)), try Fixtures.response(["household": response])
        ])
        let session = makeSession(transport)
        try await session.restore()
        let updated = try await ShoppingOperation.add.perform(session)
        #expect(updated.session?.household.value == response)
        #expect(await transport.requests.count == 2)
        let ordinary = try HouseholdShopping(household: ShoppingFixtures.snapshot(ShoppingOperation.add.successHousehold))
        #expect(ordinary.items.filter { $0.name == "Milk" }.count == 2)
    }

    @Test
    func editingIdenticalDetailsStillAcceptsTheServersVersionedSave() async throws {
        let draft = try ShoppingDraft(name: "Milk", quantity: "2 cartons", notes: "Unsweetened")
        let unchangedFields = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
            "version": .integer(5), "updatedAt": .string(ShoppingFixtures.updatedAt)
        ])
        let result = ShoppingFixtures.withReceipt(ShoppingFixtures.household(items: [unchangedFields, ShoppingFixtures.otherItem], version: 18))
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state()), try Fixtures.response(["household": result])
        ])
        let session = makeSession(transport)
        try await session.restore()
        let updated = try await session.editShoppingItem(
            id: ShoppingFixtures.itemID, draft: draft, itemVersion: 4,
            householdID: ShoppingFixtures.householdID, version: 17, mutationID: ShoppingFixtures.mutationID
        )
        #expect(updated.session?.household.value == result)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [ShoppingOperation.claim, .release, .pick, .unpick])
    func repeatedStatusWithoutAReceiptRemainsAServerConflict(operation: ShoppingOperation) async throws {
        let repeated: JSONValue
        switch operation {
        case .claim, .pick:
            repeated = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
                "claimedBy": ShoppingFixtures.id(ShoppingFixtures.memberID), "pickedUp": .bool(operation == .pick)
            ])
        case .unpick:
            repeated = ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["claimedBy": ShoppingFixtures.id(ShoppingFixtures.memberID)])
        default: repeated = ShoppingFixtures.item
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: ShoppingFixtures.household(items: [repeated]))),
            try Fixtures.failure(status: 409, code: nil)
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.server(status: 409, code: nil)) { try await operation.perform(session) }
        #expect(await transport.requests.count == 2)
        #expect(await session.state == original)
    }

    @Test(arguments: ShoppingOperation.allCases)
    func lostResponseThenRestoreThenReplayRetainsExactOriginalBytesIncludingDeletion(operation: ShoppingOperation) async throws {
        let initial = try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold))
        let refreshed = try Fixtures.response(ShoppingFixtures.state(household: operation.successHousehold))
        let replay = try Fixtures.response(["household": operation.successHousehold, "replayed": .bool(true)])
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
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await operation.perform(session)
        }
        #expect(await session.state == original)
        let restored = try await session.restore()
        let result = try await operation.perform(session)
        #expect(restored == result)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[1].httpBody == requests[3].httpBody)
        #expect(requests[1].url == requests[3].url)
        #expect(requests[1].httpMethod == requests[3].httpMethod)
        #expect(try body(requests[3])["version"] == .integer(17))
        #expect(try body(requests[3])["mutationVersion"] == .integer(17))
        #expect(try body(requests[3])["mutationId"] == ShoppingFixtures.id(ShoppingFixtures.mutationID))
        #expect(try body(requests[3])["itemVersion"] == (operation == .add ? nil : .integer(4)))
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: ShoppingOperation.allCases, [false, true])
    func replaysAcceptLaterShoppingChangesOrMissingItemsWithoutRecheckingEligibility(
        operation: ShoppingOperation, removed: Bool
    ) async throws {
        let changed = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
            "name": .string("Changed in the web app"), "quantity": .string("7"),
            "version": .integer(10), "claimedBy": ShoppingFixtures.id(ShoppingFixtures.roommateID), "pickedUp": .bool(true)
        ])
        var latest = ShoppingFixtures.withReceipt(ShoppingFixtures.household(
            items: removed ? [] : [changed, ShoppingFixtures.otherItem], version: 24
        ))
        let expense = try #require(latest["expenses"]?.arrayValue?.first)
        latest = ShoppingFixtures.replacing(latest, with: ["expenses": .array([
            ShoppingFixtures.replacing(expense, with: ["amount": .integer(2_001), "futureReceipt": .integer(Int64.max)])
        ])])
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: latest)),
            try Fixtures.response(["household": latest, "replayed": .bool(true)])
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        let result = try await operation.perform(session)
        #expect(result == original)
        #expect(result.session?.household.value == latest)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: ShoppingOperation.allCases)
    func replayedSnapshotsCannotRollBackANewerRestoredHousehold(operation: ShoppingOperation) async throws {
        let latest = ShoppingFixtures.replacing(operation.successHousehold, with: ["version": .integer(24)])
        let stale = ShoppingFixtures.replacing(operation.successHousehold, with: ["version": .integer(23)])
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: latest)),
            try Fixtures.response(["household": stale, "replayed": .bool(true)])
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: ShoppingOperation.allCases, [
        (400, Optional<AccountServerCode>.none), (403, .none), (404, .none), (409, .none), (429, .none),
        (409, .some(.mutationIDConflict)), (409, .some(.mutationPayloadChanged)), (409, .some(.mutationTooOld)),
        (401, .some(.reauthenticationRequired)), (401, .none),
        (409, .some(.accountDeletionPending)), (503, .some(.accountDeletionPending)), (500, .some(.accountSessionRequired))
    ])
    func failedRequestsPreserveHouseholdAndCredentialsWithoutRetrying(
        operation: ShoppingOperation, failure: (Int, AccountServerCode?)
    ) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)),
            try Fixtures.failure(status: failure.0, code: failure.1?.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let expected = AccountError.server(status: failure.0, code: failure.1)
        await #expect(throws: expected) { try await operation.perform(session) }
        #expect(!expected.localizedDescription.contains(Fixtures.oldToken.value))
        #expect(!String(reflecting: expected).contains("Sensitive server text"))
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func changedDetailsWithTheSameMutationIDSurfaceTheServerPayloadConflict() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state()),
            try Fixtures.response(["household": ShoppingOperation.add.successHousehold]),
            try Fixtures.failure(status: 409, code: "MUTATION_PAYLOAD_CHANGED")
        ])
        let session = makeSession(transport)
        try await session.restore()
        let saved = try await ShoppingOperation.add.perform(session)
        await #expect(throws: AccountError.server(status: 409, code: .mutationPayloadChanged)) {
            try await session.addShoppingItem(
                ShoppingDraft(name: "Changed details"), householdID: ShoppingFixtures.householdID,
                version: 17, mutationID: ShoppingFixtures.mutationID
            )
        }
        let requests = await transport.requests
        #expect(try body(requests[1])["mutationId"] == body(requests[2])["mutationId"])
        #expect(try body(requests[2])["version"] == .integer(17))
        #expect(try body(requests[2])["mutationVersion"] == .integer(17))
        #expect(await session.state == saved)
    }

    @Test(arguments: ShoppingOperation.allCases, [
        "wrong-household", "unchanged-household-version", "future-unreplayed-version", "missing-shopping",
        "bad-item", "missing-member", "inactive-member", "access-token", "replayed-false", "replayed-null",
        "replayed-string", "signed-out", "empty", "wrong-effect"
    ])
    func successShapedButInvalidResponsesAreNeverPublished(operation: ShoppingOperation, kind: String) async throws {
        var household = operation.successHousehold
        var extras: [String: JSONValue] = [:]
        switch kind {
        case "wrong-household": household = ShoppingFixtures.replacing(household, with: ["id": ShoppingFixtures.id(UUID())])
        case "unchanged-household-version": household = ShoppingFixtures.replacing(household, with: ["version": .integer(17)])
        case "future-unreplayed-version": household = ShoppingFixtures.replacing(household, with: ["version": .integer(19)])
        case "missing-shopping": household = ShoppingFixtures.removing("shopping", from: household)
        case "bad-item":
            household = ShoppingFixtures.replacing(household, with: ["shopping": .object(["items": .array([.null]), "runs": .array([])])])
        case "missing-member":
            household = ShoppingFixtures.replacing(household, with: ["members": .array(Array(ShoppingFixtures.members.dropFirst()))])
        case "inactive-member":
            let members = ShoppingFixtures.members.map { ShoppingFixtures.replacing($0, with: ["inactive": .bool(true)]) }
            household = ShoppingFixtures.replacing(household, with: ["members": .array(members)])
        case "access-token": extras["accessToken"] = .null
        case "replayed-false": extras["replayed"] = .bool(false)
        case "replayed-null": extras["replayed"] = .null
        case "replayed-string": extras["replayed"] = .string("true")
        case "wrong-effect":
            household = ShoppingFixtures.replacing(operation.initialHousehold, with: ["version": .integer(18)])
        default: break
        }
        var envelope = extras.merging(["household": household]) { _, new in new }
        if kind == "signed-out" { envelope = Fixtures.state(signedIn: false) }
        if kind == "empty" { envelope = ["saved": .bool(true)] }
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)), try Fixtures.response(envelope)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: [ShoppingOperation.edit, .claim, .release, .pick, .unpick], [
        "skipped-version", "changed-creator", "changed-source", "wrong-owner", "changed-neighbor"
    ])
    func freshSuccessMustConfirmExactlyTheRequestedItemChange(operation: ShoppingOperation, kind: String) async throws {
        let success = operation.successHousehold
        var items = try #require(success["shopping"]?["items"]?.arrayValue)
        switch kind {
        case "skipped-version": items[0] = ShoppingFixtures.replacing(items[0], with: ["version": .integer(6)])
        case "changed-creator": items[0] = ShoppingFixtures.replacing(items[0], with: ["createdBy": ShoppingFixtures.id(ShoppingFixtures.memberID)])
        case "changed-source": items[0] = ShoppingFixtures.replacing(items[0], with: ["componentSources": .array([])])
        case "wrong-owner":
            items[0] = ShoppingFixtures.replacing(items[0], with: ["claimedBy": ShoppingFixtures.id(ShoppingFixtures.inactiveID)])
        default: items[1] = ShoppingFixtures.replacing(items[1], with: ["name": .string("Unrelated change")])
        }
        let household = ShoppingFixtures.replacing(success, with: ["shopping": .object(["items": .array(items), "runs": .array(ShoppingFixtures.runs)])])
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)), try Fixtures.response(["household": household])
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: [false, true], [
        "missing", "empty", "wrong-id", "wrong-member", "wrong-version", "future-version", "bad-fingerprint",
        "duplicate", "out-of-order", "too-many", "bad-value"
    ])
    func mutationsMustConfirmTheOriginalMutationReceiptWithoutTrustingASuccessFlag(replayed: Bool, kind: String) async throws {
        var household = ShoppingOperation.pick.successHousehold
        var receipts = try #require(household["mutationReceipts"]?.arrayValue)
        switch kind {
        case "empty": receipts = []
        case "wrong-id": receipts[0] = ShoppingFixtures.replacing(receipts[0], with: ["id": ShoppingFixtures.id(UUID())])
        case "wrong-member": receipts[0] = ShoppingFixtures.replacing(receipts[0], with: ["memberId": ShoppingFixtures.id(ShoppingFixtures.roommateID)])
        case "wrong-version": receipts[0] = ShoppingFixtures.replacing(receipts[0], with: ["version": .integer(17)])
        case "future-version": receipts[0] = ShoppingFixtures.replacing(receipts[0], with: ["version": .integer(19)])
        case "bad-fingerprint": receipts[0] = ShoppingFixtures.replacing(receipts[0], with: ["fingerprint": .string("not-a-fingerprint")])
        case "duplicate": receipts.append(receipts[0])
        case "out-of-order":
            receipts.append(ShoppingFixtures.replacing(receipts[0], with: ["id": ShoppingFixtures.id(UUID()), "version": .integer(17)]))
        case "too-many": receipts = Array(repeating: receipts[0], count: 1_001)
        case "bad-value": receipts = [.null]
        default: break
        }
        household = kind == "missing" ? ShoppingFixtures.removing("mutationReceipts", from: household)
            : ShoppingFixtures.replacing(household, with: ["mutationReceipts": .array(receipts)])
        var envelope: [String: JSONValue] = ["household": household]
        if replayed { envelope["replayed"] = .bool(true) }
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state()), try Fixtures.response(envelope)
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await ShoppingOperation.pick.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: ShoppingOperation.allCases, ["network", "cancelled", "unknown", "redirect", "cross-origin", "malformed-json"])
    func transportFailuresAreSanitizedAndCookieOrRedirectFallbacksAreNeverAttempted(
        operation: ShoppingOperation, kind: String
    ) async throws {
        let initial = try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold))
        let data = try Fixtures.data(["household": operation.successHousehold])
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            switch kind {
            case "network": throw URLError(.notConnectedToInternet)
            case "cancelled": throw URLError(.cancelled)
            case "unknown": throw SensitiveFailure(detail: Fixtures.oldToken.value)
            case "redirect": return try Fixtures.failure(status: 307, code: nil)
            case "cross-origin":
                return HTTPResponse(data: data, statusCode: 200, url: URL(string: "https://other.example/api/shopping/items")!)
            default: return HTTPResponse(data: Data("{".utf8), statusCode: 200, url: Fixtures.configuration.origin)
            }
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        if kind == "cancelled" {
            await #expect(throws: CancellationError.self) { try await operation.perform(session) }
        } else {
            let expected: AccountError
            switch kind {
            case "network": expected = .network(code: URLError.notConnectedToInternet.rawValue)
            case "unknown": expected = .network(code: nil)
            case "redirect": expected = .redirectRejected
            case "cross-origin": expected = .untrustedResponse
            default: expected = .invalidResponse
            }
            await #expect(throws: expected) { try await operation.perform(session) }
        }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    private func makeSession(_ transport: any HTTPTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }
}
