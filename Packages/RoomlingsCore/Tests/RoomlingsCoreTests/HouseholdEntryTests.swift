import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Household entry", .timeLimit(.minutes(1)))
struct HouseholdEntryTests {
    @Test(arguments: [
        (HouseholdCurrency.eur, Int64(1_999)), (.usd, 1), (.gbp, 100_000_000), (.ron, 45_000)
    ])
    func createsWithIntegerCentsAndLowercaseRequestID(currency: HouseholdCurrency, budget: Int64) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state()),
            try Fixtures.response(Fixtures.entryState(), status: 201)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        let state = try await session.createHousehold(
            name: " Our kitchen ", memberName: " Roommate\n", currency: currency,
            budgetCents: budget, requestID: Fixtures.entryRequestID
        )
        let request = try #require(await transport.requests.last)
        expectNativeRequest(request, path: "/api/account/households")
        #expect(try body(request) == .object([
            "name": .string("Our kitchen"), "memberName": .string("Roommate"),
            "currency": .string(currency.rawValue), "budget": .integer(budget),
            "requestId": .string(Fixtures.entryRequestID.uuidString.lowercased())
        ]))
        #expect(await session.state == state)
        #expect(await session.selectedHousehold?.id == Fixtures.entryHouseholdID)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func explicitCreationRetryKeepsTheCallersRequestIDAndPayload() async throws {
        let response = try Fixtures.response(Fixtures.entryState(), status: 201)
        let transport = TestTransport { _, index in
            if index == 0 { throw URLError(.networkConnectionLost) }
            return response
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await EntryOperation.create.perform(session)
        }
        #expect(await transport.requests.count == 1)
        #expect(await store.token == Fixtures.oldToken)
        try await EntryOperation.create.perform(session)
        let requests = await transport.requests
        #expect(requests.count == 2)
        let firstBody = try body(#require(requests.first))
        #expect(try firstBody == body(#require(requests.last)))
        #expect(firstBody["requestId"] == .string(Fixtures.entryRequestID.uuidString.lowercased()))
        #expect(await store.saveAttempts == 0)
    }

    @Test(arguments: [Int64(-1), 0, 100_000_001, Int64.max])
    func rejectsInvalidBudgetsBeforeSending(budget: Int64) async throws {
        let transport = TestTransport(responses: [])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidInput(.budgetCents)) {
            try await session.createHousehold(
                name: "Kitchen", memberName: "Roommate", currency: .eur,
                budgetCents: budget, requestID: Fixtures.entryRequestID
            )
        }
        #expect(await transport.requests.isEmpty)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: [" ", String(repeating: "x", count: 51)])
    func validatesBothHouseholdAndMemberNames(name: String) async throws {
        let transport = TestTransport(responses: [])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidInput(.name)) {
            try await session.createHousehold(
                name: name, memberName: "Roommate", currency: .eur,
                budgetCents: 1_999, requestID: Fixtures.entryRequestID
            )
        }
        await #expect(throws: AccountError.invalidInput(.memberName)) {
            try await session.createHousehold(
                name: "Kitchen", memberName: name, currency: .eur,
                budgetCents: 1_999, requestID: Fixtures.entryRequestID
            )
        }
        await #expect(throws: AccountError.invalidInput(.memberName)) {
            try await session.acceptInvitation(code: Fixtures.invitationCode, memberName: name)
        }
        #expect(await transport.requests.isEmpty)
        #expect(await store.token == Fixtures.oldToken)
    }

    @Test(arguments: ["raw", "trimmed", "https", "http", "encoded", "form-spaces"])
    func acceptsRawOrLocallyParsedInvitationsWithoutChangingCase(format: String) async throws {
        let code = Fixtures.invitationCode
        let input: String
        switch format {
        case "raw": input = code
        case "trimmed": input = " \n\(code) "
        case "https": input = "https://web.example/welcome?source=share#account-invite=\(code)"
        case "http": input = "http://localhost:5173/#account-invite=\(code)"
        case "encoded":
            let encoded = code.replacingOccurrences(of: "-", with: "%2D").replacingOccurrences(of: "_", with: "%5F")
            input = "https://web.example/#source=share&%61ccount-invite=\(encoded)&extra=1"
        default: input = "https://web.example/#account-invite=+\(code)%20"
        }
        let transport = TestTransport(response: try Fixtures.response(Fixtures.entryState()))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let state = try await session.acceptInvitation(code: input, memberName: " Roommate ")
        let request = try #require(await transport.requests.first)
        expectNativeRequest(request, path: "/api/account/invitations/accept")
        #expect(request.url?.host == Fixtures.configuration.origin.host)
        #expect(try body(request) == .object(["code": .string(code), "memberName": .string("Roommate")]))
        #expect(await session.state == state)
        #expect(await session.selectedHousehold?.id == Fixtures.entryHouseholdID)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        "", "roomlings-kitchen-invite-abcd", Fixtures.recoveryCode,
        "roomlings-invite-" + String(repeating: "a", count: 42),
        "roomlings-invite-" + String(repeating: "a", count: 44),
        "ROOMLINGS-INVITE-" + String(repeating: "a", count: 43),
        "https://web.example/?account-invite=\(Fixtures.invitationCode)",
        "https://web.example/#invite=\(Fixtures.invitationCode)",
        "https://web.example/#account-invite",
        "https://web.example/#account-invite=",
        "https://web.example/#account-invite=\(Fixtures.invitationCode)&account-invite=\(Fixtures.invitationCode)",
        "https://web.example/#account-invite=\(Fixtures.invitationCode)&%61ccount-invite=other",
        "https://web.example/#account-invite=\(Fixtures.invitationCode)&account-invite",
        "https://web.example/#account-invite=%ZZ\(Fixtures.invitationCode)",
        "https://web.example/#account-invite=%2572oomlings-invite-" + String(repeating: "a", count: 43),
        "https:///#account-invite=\(Fixtures.invitationCode)",
        "https://bad host.example/#account-invite=\(Fixtures.invitationCode)",
        "https://user:password@web.example/#account-invite=\(Fixtures.invitationCode)",
        "javascript://web.example/#account-invite=\(Fixtures.invitationCode)"
    ])
    func rejectsMissingAmbiguousMalformedOrLegacyInvitations(input: String) async throws {
        let transport = TestTransport(responses: [])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        await #expect(throws: AccountError.invalidInput(.invitationCode)) {
            try await session.acceptInvitation(code: input, memberName: "Roommate")
        }
        #expect(await transport.requests.isEmpty)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test
    func selectionUsesLowercaseUUIDAndPreservesRawServerSnapshot() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(Fixtures.entryState())
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        try await session.restore()
        let state = try await session.selectHousehold(id: Fixtures.entryHouseholdID)
        let request = try #require(await transport.requests.last)
        expectNativeRequest(
            request, path: "/api/account/households/\(Fixtures.entryHouseholdID.uuidString.lowercased())/select"
        )
        #expect(try body(request) == .object([:]))
        #expect(await session.state == state)
        let household = try #require(await session.selectedHousehold)
        #expect(household.id == Fixtures.entryHouseholdID)
        #expect(household.value["id"] == .string(Fixtures.entryHouseholdID.uuidString.lowercased()))
        #expect(household.value["budget"] == Fixtures.household["budget"])
        #expect(household.value["expenses"] == Fixtures.household["expenses"])
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: EntryOperation.allCases, [
        (403, Optional<AccountServerCode>.none),
        (409, .some(.accountCreationConflict)),
        (409, .some(.accountDeletionPending)),
        (503, .some(.accountDeletionPending)),
        (401, .some(.reauthenticationRequired)),
        (401, .none),
        (500, .some(.accountSessionRequired))
    ])
    func mutationFailuresKeepStateAndCredentials(
        operation: EntryOperation, failure: (Int, AccountServerCode?)
    ) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: failure.0, code: failure.1?.rawValue)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.server(status: failure.0, code: failure.1)) {
            try await operation.perform(session)
        }
        #expect(await session.state == previous)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: EntryOperation.allCases)
    func networkFailuresNeverRetryOrSignOut(operation: EntryOperation) async throws {
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            throw URLError(.networkConnectionLost)
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await operation.perform(session)
        }
        #expect(await session.state == previous)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: EntryOperation.allCases)
    func confirmedExpiryClearsCredentialsAndSelectedHousehold(operation: EntryOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: 401, code: AccountServerCode.accountSessionRequired.rawValue)
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
        #expect(await store.clearAttempts == 1)
        #expect(await store.saveAttempts == 0)
    }

    @Test(arguments: EntryOperation.allCases, ["access-token", "signed-out", "malformed"])
    func invalidSuccessResponsesCannotChangeStateOrCredentials(operation: EntryOperation, kind: String) async throws {
        var object = Fixtures.entryState()
        switch kind {
        case "access-token": object["accessToken"] = .string(Fixtures.newToken.value)
        case "signed-out": object = Fixtures.state(signedIn: false)
        default: object.removeValue(forKey: "session")
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(object)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let previous = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == previous)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test(arguments: EntryOperation.allCases)
    func cannotPublishSignedInMutationWithoutStoredBearer(operation: EntryOperation) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.entryState()))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(), transport: transport
        )
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == nil)
    }

    @Test
    func householdMutationsShareTheExistingOperationGate() async throws {
        let started = Signal()
        let finish = Signal()
        let response = try Fixtures.response(Fixtures.entryState(), status: 201)
        let transport = TestTransport { _, _ in
            await started.signal()
            await finish.wait()
            return response
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let creation = Task { try await EntryOperation.create.perform(session) }
        await started.wait()
        #expect(await session.isBusy)
        #expect(await session.state == nil)
        for operation in EntryOperation.allCases {
            await #expect(throws: AccountError.operationInProgress) { try await operation.perform(session) }
        }
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await finish.signal()
        let state = try await creation.value
        #expect(await session.state == state)
        #expect(await session.isBusy == false)
        #expect(await transport.requests.count == 1)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
    }

    private func expectNativeRequest(_ request: URLRequest, path: String) {
        #expect(request.url?.path == path)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(!request.httpShouldHandleCookies)
        for header in ["Cookie", "Origin", "Sec-Fetch-Site", "X-CSRF-Token", "X-Roomlings-Request"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }
}

enum EntryOperation: CaseIterable, Sendable {
    case create, accept, select

    @discardableResult
    func perform(_ session: AccountSession) async throws -> AccountState {
        switch self {
        case .create:
            try await session.createHousehold(
                name: "Kitchen", memberName: "Roommate", currency: .eur,
                budgetCents: 1_999, requestID: Fixtures.entryRequestID
            )
        case .accept:
            try await session.acceptInvitation(code: Fixtures.invitationCode, memberName: "Roommate")
        case .select:
            try await session.selectHousehold(id: Fixtures.entryHouseholdID)
        }
    }
}

private extension Fixtures {
    static let entryRequestID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!
    static let entryHouseholdID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDE0")!
    static let invitationCode = "roomlings-invite-Ab_-0123" + String(repeating: "Z", count: 35)

    static func entryState() -> [String: JSONValue] {
        var state = Fixtures.state(selectedHousehold: true)
        guard case .object(var membership) = Fixtures.membership,
              case .object(var household) = Fixtures.household else {
            preconditionFailure("Invalid test fixture")
        }
        let id = entryHouseholdID.uuidString.lowercased()
        membership["householdId"] = .string(id)
        household["id"] = .string(id)
        state["memberships"] = .array([.object(membership)])
        state["session"] = .object(["token": .null, "memberId": .string(memberID), "household": .object(household)])
        return state
    }
}
