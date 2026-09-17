import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Shopping account coordination", .timeLimit(.minutes(1)))
struct ShoppingSessionSafetyTests {
    @Test(arguments: ShoppingOperation.allCases, ["no-state", "signed-out", "unselected", "deleting", "inactive"])
    func everyShoppingCallRequiresAnActiveRestoredAccountAndHousehold(operation: ShoppingOperation, kind: String) async throws {
        let state: [String: JSONValue]
        switch kind {
        case "signed-out": state = Fixtures.state(signedIn: false)
        case "unselected": state = Fixtures.state()
        case "deleting": state = Fixtures.state(deletionPending: true)
        case "inactive":
            state = ShoppingFixtures.state(household: ShoppingFixtures.replacing(operation.initialHousehold, with: [
                "members": .array(ShoppingFixtures.members.map { ShoppingFixtures.replacing($0, with: ["inactive": .bool(true)]) })
            ]))
        default: state = ShoppingFixtures.state(household: operation.initialHousehold)
        }
        let transport = TestTransport(response: try Fixtures.response(state))
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

    @Test(arguments: ShoppingOperation.allCases, ["wrong-household", "missing-token", "replaced-token"])
    func intendedHouseholdAndCredentialMustStillMatchTheRestoredIdentity(operation: ShoppingOperation, kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        if kind != "wrong-household" { await store.replaceToken(kind == "missing-token" ? nil : Fixtures.newToken) }
        let expected: AccountError = kind == "wrong-household" ? .householdSelectionChanged : .accountStateRequired
        await #expect(throws: expected) {
            try await operation.perform(session, householdID: kind == "wrong-household" ? UUID() : ShoppingFixtures.householdID)
        }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ShoppingOperation.allCases, [Int64(-1), HouseholdValidation.maximumInteger, Int64.max])
    func invalidHouseholdVersionsNeverSendARequest(operation: ShoppingOperation, version: Int64) async throws {
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)))
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidInput(.version)) { try await operation.perform(session, version: version) }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [ShoppingOperation.edit, .remove, .claim, .release, .pick, .unpick], [Int64(-1), Int64.max])
    func invalidItemVersionsNeverSendARequest(operation: ShoppingOperation, version: Int64) async throws {
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)))
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidInput(.itemVersion)) { try await operation.perform(session, itemVersion: version) }
        #expect(await session.state == original)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func deletionAcceptsTheSharedMaximumItemVersionBecauseItDoesNotIncrementTheItem() async throws {
        let maximum = HouseholdValidation.maximumInteger
        let item = ShoppingFixtures.replacing(ShoppingFixtures.item, with: ["version": .integer(maximum)])
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: ShoppingFixtures.household(items: [item, ShoppingFixtures.otherItem]))),
            try Fixtures.response(["household": ShoppingOperation.remove.successHousehold])
        ])
        let session = makeSession(transport)
        try await session.restore()
        let updated = try await ShoppingOperation.remove.perform(session, itemVersion: maximum)
        #expect(updated.session?.household.value == ShoppingOperation.remove.successHousehold)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [ShoppingOperation.edit, .claim, .release, .pick, .unpick])
    func itemMutationsCannotOverflowTheSharedIntegerRange(operation: ShoppingOperation) async throws {
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)))
        let session = makeSession(transport)
        try await session.restore()
        await #expect(throws: AccountError.invalidInput(.itemVersion)) {
            try await operation.perform(session, itemVersion: HouseholdValidation.maximumInteger)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ShoppingOperation.allCases)
    func anAlreadyRestoredMutationMustBeIdentifiedAsAReplay(operation: ShoppingOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.successHousehold)),
            try Fixtures.response(["household": operation.successHousehold])
        ])
        let session = makeSession(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == original)
    }

    @Test(arguments: ShoppingOperation.allCases, ["cleared", "failed-keychain", "failed-storage"])
    func confirmedExpiryIsTheOnlyShoppingFailureThatClearsCredentials(operation: ShoppingOperation, kind: String) async throws {
        let failure: (any Error)?
        switch kind {
        case "failed-keychain": failure = KeychainError.status(operation: .clear, status: -25308)
        case "failed-storage": failure = SensitiveFailure(detail: Fixtures.oldToken.value)
        default: failure = nil
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold)),
            try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearFailure: failure)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        if kind == "failed-keychain" {
            await #expect(throws: KeychainError.status(operation: .clear, status: -25308)) { try await operation.perform(session) }
        } else {
            let expected: AccountError = kind == "failed-storage" ? .credentialStorage : .server(status: 401, code: .accountSessionRequired)
            await #expect(throws: expected) { try await operation.perform(session) }
        }
        #expect(await store.clearAttempts == 1)
        #expect(await store.saveAttempts == 0)
        #expect(await store.token == (kind == "cleared" ? nil : Fixtures.oldToken))
        #expect(await session.state == (kind == "cleared" ? nil : original))
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ["keychain", "unknown", "cancelled"])
    func failedCredentialReadsNeverFallBackToAnonymousShopping(kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let failure: any Error
        switch kind {
        case "keychain": failure = KeychainError.status(operation: .read, status: -25308)
        case "cancelled": failure = CancellationError()
        default: failure = SensitiveFailure(detail: Fixtures.oldToken.value)
        }
        await store.setReadFailure(failure)
        for operation in ShoppingOperation.allCases {
            switch kind {
            case "keychain":
                await #expect(throws: KeychainError.status(operation: .read, status: -25308)) { try await operation.perform(session) }
            case "cancelled":
                await #expect(throws: CancellationError.self) { try await operation.perform(session) }
            default:
                await #expect(throws: AccountError.credentialStorage) { try await operation.perform(session) }
            }
        }
        #expect(await transport.requests.count == 1)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
    }

    @Test
    func shoppingSharesTheOperationGateWithEveryAccountHouseholdAndChoreAction() async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(ShoppingFixtures.state())
        let success = try Fixtures.response(["household": ShoppingOperation.add.successHousehold])
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return success
        }
        let session = makeSession(transport)
        let original = try await session.restore()
        let pending = Task { try await ShoppingOperation.add.perform(session) }
        await started.wait()
        #expect(await session.isBusy)
        #expect(await session.state == original)
        for operation in ShoppingOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        for operation in ChoreOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.undoChoreCompletion(
                id: ChoreFixtures.completionID, choreVersion: 1, householdID: ChoreFixtures.householdID,
                version: 17, mutationID: UUID()
            )
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await session.selectHousehold(id: UUID()) }
        await #expect(throws: AccountError.operationInProgress) { try await session.sendEmailCode(email: "roommate@example.com") }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.createHousehold(name: "Home", memberName: "Alex", currency: .eur, budgetCents: 45_000, requestID: UUID())
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.acceptInvitation(code: "invalid", memberName: "Alex") }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.verifyEmailCode(email: "roommate@example.com", code: "123456", name: "Alex", deviceLabel: "iPhone")
        }
        await #expect(throws: AccountError.operationInProgress) {
            try await session.recover(email: "roommate@example.com", recoveryCode: Fixtures.recoveryCode, deviceLabel: "iPhone")
        }
        await finish.signal()
        let result = try await pending.value
        #expect(await session.state == result)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func shoppingCannotRacePendingCredentialPersistence() async throws {
        let started = Signal()
        let finish = Signal()
        var signedIn = ShoppingFixtures.state()
        signedIn["accessToken"] = .string(Fixtures.newToken.value)
        let transport = TestTransport(response: try Fixtures.response(signedIn))
        let store = MemoryTokenStore(token: Fixtures.oldToken, saveStarted: started, finishSave: finish)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let pending = Task {
            try await session.verifyEmailCode(email: "roommate@example.com", code: "123456", name: "Alex", deviceLabel: "iPhone")
        }
        await started.wait()
        for operation in ShoppingOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        #expect(await session.state == nil)
        await finish.signal()
        _ = try await pending.value
        #expect(await store.token == Fixtures.newToken)
        #expect(await transport.requests.count == 1)
        #expect(await session.isBusy == false)
    }

    @Test
    func shoppingExpiryKeepsTheGateUntilCredentialClearingFinishes() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state()), try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken, clearStarted: started, finishClear: finish)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let pending = Task { try await ShoppingOperation.add.perform(session) }
        await started.wait()
        #expect(await session.state == original)
        #expect(await session.isBusy)
        for operation in ShoppingOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await finish.signal()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await pending.value }
        #expect(await session.state == nil)
        #expect(await store.token == nil)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ShoppingOperation.allCases)
    func cancellationAfterSendingCannotPublishALateSuccess(operation: ShoppingOperation) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(ShoppingFixtures.state(household: operation.initialHousehold))
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
        pending.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await session.state == original)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func cancellationDuringCredentialReadCannotSendTheMutationAfterTheReadFinishes() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport(response: try Fixtures.response(ShoppingFixtures.state()))
        let store = ShoppingReadGateStore(started: started, finish: finish)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let original = try await session.restore()
        let pending = Task { try await ShoppingOperation.add.perform(session) }
        await started.wait()
        for operation in ShoppingOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        pending.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 1)
    }

    private func makeSession(_ transport: any HTTPTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}

private actor ShoppingReadGateStore: SessionTokenStore {
    let started: Signal
    let finish: Signal
    private var reads = 0

    init(started: Signal, finish: Signal) {
        self.started = started
        self.finish = finish
    }

    func read() async throws -> SessionToken? {
        reads += 1
        if reads > 1 {
            await started.signal()
            await finish.wait()
        }
        return Fixtures.oldToken
    }

    func save(_ token: SessionToken) async throws { throw TestFailure.storage }
    func clear() async throws { throw TestFailure.storage }
}
