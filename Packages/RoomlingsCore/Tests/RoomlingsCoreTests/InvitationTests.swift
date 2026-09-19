import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Household invitations", .timeLimit(.minutes(1)))
struct InvitationTests {
    @Test(arguments: InvitationOperation.allCases)
    func usesNativeRoutesAndPublishesOnlyTheSelectedHousehold(operation: InvitationOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try operation.response()
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let before = try await session.restore()
        try await operation.perform(session)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == operation.method)
        #expect(request.url?.path == operation.path)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        #expect(!request.httpShouldHandleCookies)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        if operation == .load {
            #expect(request.httpBody == nil)
        } else {
            let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
            var expected: [String: JSONValue] = ["version": .integer(17)]
            if operation == .create { expected["expiresInDays"] = .integer(7) }
            #expect(payload == .object(expected))
        }
        let after = try #require(await session.state)
        #expect(after.account == before.account)
        #expect(after.devices == before.devices)
        #expect(after.memberships == before.memberships)
        #expect(after.session?.household.version == 18)
        #expect(after.session?.household.value["unrecognizedServerField"] == Fixtures.household["unrecognizedServerField"])
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.saveAttempts == 0)
        #expect(await store.clearAttempts == 0)
    }

    @Test
    func creationReturnsTheCaseSensitiveCodeOnlyInItsCreationResponse() async throws {
        let result = try JSONDecoder().decode(CreatedHouseholdInvitation.self, from: Fixtures.data(Fixtures.createdInvitation()))
        #expect(result.code.value == Fixtures.invitationCode)
        #expect(result.access.invitations == [result.invitation])
        #expect(!String(describing: result).contains(Fixtures.invitationCode))
        #expect(!String(reflecting: result).contains(Fixtures.invitationCode))
        #expect(!String(describing: result.code).contains(Fixtures.invitationCode))
        #expect(!String(reflecting: result.code).contains(Fixtures.invitationCode))
        #expect(Mirror(reflecting: result.code).children.isEmpty)
        #expect(Mirror(reflecting: result).children.map(\.label) == ["id"])
    }

    @Test
    func pendingMeansNotRevokedAndNotExpiredEvenAfterSomeoneHasJoined() throws {
        let created = try #require(AccountValidation.instant("2026-09-13T12:00:00.000Z"))
        let expiry = try #require(AccountValidation.instant("2026-09-20T12:00:00Z"))
        let invitation = try JSONDecoder().decode(
            HouseholdInvitation.self, from: Fixtures.data(Fixtures.invitation(uses: 3))
        )
        #expect(invitation.isPending(at: created))
        #expect(invitation.isPending(at: expiry.addingTimeInterval(-0.001)))
        #expect(!invitation.isPending(at: expiry))
        let revoked = try JSONDecoder().decode(
            HouseholdInvitation.self, from: Fixtures.data(Fixtures.invitation(revoked: true))
        )
        #expect(!revoked.isPending(at: created))
    }

    @Test(arguments: [
        ["uses": JSONValue.integer(-1)], ["uses": .number(1.5)],
        ["createdAt": .string("2026-02-30T00:00:00Z")], ["expiresAt": .string("yesterday")],
        ["expiresAt": .string("2026-09-13T12:00:00.000Z")], ["revokedAt": .string("not-a-date")],
        ["id": .string("not-a-uuid")]
    ])
    func rejectsMalformedInvitationMetadata(changes: [String: JSONValue]) throws {
        let fields = Fixtures.invitation().merging(changes) { _, new in new }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HouseholdInvitation.self, from: Fixtures.data(fields))
        }
    }

    @Test(arguments: ["missing-created", "wrong-code", "used-created", "revoked-created", "other-role", "access-token"])
    func rejectsCreationResponsesThatDoNotConfirmTheNewLink(fault: String) throws {
        var result = Fixtures.createdInvitation()
        switch fault {
        case "missing-created": result["access"] = .object(Fixtures.invitationAccess(invitations: []))
        case "wrong-code": result["code"] = .string(Fixtures.recoveryCode)
        case "used-created": result["invitation"] = .object(Fixtures.invitation(uses: 1))
        case "revoked-created": result["invitation"] = .object(Fixtures.invitation(revoked: true))
        case "other-role": result["access"] = .object(Fixtures.invitationAccess(role: "admin", invitations: []))
        default: result["accessToken"] = .string(Fixtures.newToken.value)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CreatedHouseholdInvitation.self, from: Fixtures.data(result))
        }
    }

    @Test(arguments: ["duplicate", "member-invitations", "unknown-member", "inactive", "access-token"])
    func rejectsUnusableHouseholdAccess(fault: String) throws {
        var access = Fixtures.invitationAccess()
        switch fault {
        case "duplicate": access["invitations"] = .array([.object(Fixtures.invitation()), .object(Fixtures.invitation())])
        case "member-invitations": access["role"] = .string("member")
        case "unknown-member": access["memberId"] = .string(Fixtures.deviceID)
        case "inactive":
            var household = try HouseholdFields(#require(access["household"])).object
            household["members"] = .array([.object([
                "id": .string(Fixtures.memberID), "name": .string("Roommate"),
                "color": .string("#7d9070"), "inactive": .bool(true)
            ])])
            access["household"] = .object(household)
        default: access["accessToken"] = .string(Fixtures.newToken.value)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HouseholdInvitationAccess.self, from: Fixtures.data(access))
        }
    }

    @Test(arguments: ["admin", "member"])
    func acceptsReadOnlyAccessWithoutInvitationHistory(role: String) throws {
        let access = try JSONDecoder().decode(
            HouseholdInvitationAccess.self,
            from: Fixtures.data(Fixtures.invitationAccess(role: role, invitations: []))
        )
        #expect(access.role.rawValue == role)
        #expect(access.invitations.isEmpty)
    }

    @Test(arguments: InvitationOperation.allCases, [403, 409, 410, 429, 503])
    func failuresKeepCredentialsAndNeverRetry(operation: InvitationOperation, status: Int) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: status, code: nil)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let before = try await session.restore()
        await #expect(throws: AccountError.server(status: status, code: nil)) {
            try await operation.perform(session)
        }
        #expect(await session.state == before)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await store.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: InvitationOperation.allCases)
    func uncertainSavesAreNotRetried(operation: InvitationOperation) async throws {
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            throw URLError(.networkConnectionLost)
        }
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        let before = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await operation.perform(session)
        }
        #expect(await transport.requests.count == 2)
        #expect(await session.state == before)
        #expect(await store.token == Fixtures.oldToken)
    }

    @Test(arguments: InvitationOperation.allCases)
    func confirmedExpiryClearsNativeAccess(operation: InvitationOperation) async throws {
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
        #expect(await store.token == nil)
        #expect(await store.clearAttempts == 1)
    }

    @Test(arguments: InvitationOperation.allCases)
    func rejectsAnotherSelectedHousehold(operation: InvitationOperation) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.entryState()))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        await #expect(throws: AccountError.householdSelectionChanged) { try await operation.perform(session) }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: InvitationOperation.allCases, ["unrestored", "no-household", "signed-out", "deleting", "replaced-token", "storage"])
    func requiresTheRestoredNativeAccount(operation: InvitationOperation, condition: String) async throws {
        let initial = Fixtures.state(
            signedIn: condition != "signed-out",
            selectedHousehold: ["replaced-token", "storage"].contains(condition),
            deletionPending: condition == "deleting"
        )
        let transport = TestTransport(response: try Fixtures.response(initial))
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport)
        if condition != "unrestored" { try await session.restore() }
        if condition == "replaced-token" { await store.replaceToken(Fixtures.newToken) }
        if condition == "storage" { await store.setReadFailure(TestFailure.storage) }
        let count = await transport.requests.count
        let expected: AccountError = condition == "storage" ? .credentialStorage : .accountStateRequired
        await #expect(throws: expected) { try await operation.perform(session) }
        #expect(await transport.requests.count == count)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ["old-version", "other-household", "other-member"])
    func neverPublishesCrossHouseholdOrStaleAccess(fault: String) async throws {
        var access = Fixtures.invitationAccess(version: fault == "old-version" ? 16 : 18)
        var household = try HouseholdFields(#require(access["household"])).object
        if fault == "other-household" { household["id"] = .string(Fixtures.entryHouseholdID.uuidString.lowercased()) }
        if fault == "other-member" {
            household["members"] = .array([
                try #require(household["members"]?.arrayValue?.first),
                .object(["id": .string(Fixtures.deviceID), "name": .string("Other"), "color": .string("#7d9070")])
            ])
            access["memberId"] = .string(Fixtures.deviceID)
        }
        access["household"] = .object(household)
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(access)
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        let before = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await InvitationOperation.load.perform(session) }
        #expect(await session.state == before)
    }

    @Test(arguments: [Int64(-1), HouseholdValidation.maximumInteger, Int64.max])
    func rejectsInvalidMutationVersionsBeforeSending(version: Int64) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        await #expect(throws: AccountError.invalidInput(.version)) {
            try await session.createInvitation(householdID: Fixtures.invitedHouseholdID, version: version)
        }
        await #expect(throws: AccountError.invalidInput(.version)) {
            try await session.revokeInvitation(id: Fixtures.invitationID, householdID: Fixtures.invitedHouseholdID, version: version)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [17, 18])
    func revokeCanConfirmAnAlreadyRevokedLinkWithoutAnotherVersionChange(version: Int) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(Fixtures.invitationAccess(version: Int64(version), invitations: [Fixtures.invitation(revoked: true)]))
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        try await InvitationOperation.revoke.perform(session)
        #expect(await session.selectedHousehold?.version == Int64(version))
    }

    @Test(arguments: ["create-version", "revoke-version", "not-revoked", "wrong-invitation"])
    func rejectsUnconfirmedInvitationChanges(fault: String) async throws {
        var invitation = Fixtures.invitation(revoked: fault != "not-revoked")
        if fault == "wrong-invitation" { invitation["id"] = .string(Fixtures.deviceID) }
        let access = Fixtures.invitationAccess(
            version: fault.hasSuffix("version") ? 19 : 18, invitations: [invitation]
        )
        var result = access
        let operation: InvitationOperation = fault == "create-version" ? .create : .revoke
        if operation == .create {
            result = Fixtures.createdInvitation()
            result["access"] = .object(Fixtures.invitationAccess(version: 19))
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(result)
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        let before = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == before)
    }

    @Test(arguments: InvitationOperation.allCases)
    func cancellationCannotPublishALateInvitationResponse(operation: InvitationOperation) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let result = try operation.response()
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return result
        }
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        let before = try await session.restore()
        let task = Task { try await operation.perform(session) }
        await started.wait()
        task.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.state == before)
        #expect(await transport.requests.count == 2)
        #expect(await session.isBusy == false)
    }

    @Test
    func invitationRequestsShareTheAccountOperationGate() async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(Fixtures.state(selectedHousehold: true))
        let loaded = try InvitationOperation.load.response()
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return loaded
        }
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        let load = Task { try await InvitationOperation.load.perform(session) }
        await started.wait()
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await InvitationOperation.create.perform(session) }
        await finish.signal()
        try await load.value
        #expect(await session.isBusy == false)
    }

    @Test
    func linksRoundTripWithoutChangingCaseOrPuttingTheCodeInRequests() throws {
        let code = try AccountInvitationCode(Fixtures.invitationCode)
        let origin = try APIConfiguration(origin: "https://invites.roomlings.example")
        let link = try code.link(origin: origin)
        #expect(link.absoluteString == "https://invites.roomlings.example/#account-invite=\(Fixtures.invitationCode)")
        #expect(link.query == nil)
        #expect(try AccountInvitationCode(link: link, origin: origin) == code)
        #expect(try AccountInvitationCode(link: #require(URL(string: "https://INVITES.roomlings.example:443/#account-invite=\(code.value)")), origin: origin) == code)
    }

    @Test
    func localLinksNeedNoPublicDomain() throws {
        let origin = try APIConfiguration(origin: "http://localhost:5173")
        let code = try AccountInvitationCode(Fixtures.invitationCode)
        let link = try code.link(origin: origin)
        #expect(link.absoluteString == "http://localhost:5173/#account-invite=\(Fixtures.invitationCode)")
        #expect(try AccountInvitationCode(link: link, origin: origin) == code)
    }

    @Test(arguments: [
        "https://other.example", "http://invites.roomlings.example", "https://invites.roomlings.example:8443",
        "https://user@invites.roomlings.example", "https://invites.roomlings.example.attacker.test"
    ])
    func incomingLinksMustUseTheConfiguredOrigin(untrusted: String) throws {
        let origin = try APIConfiguration(origin: "https://invites.roomlings.example")
        let link = try #require(URL(string: "\(untrusted)/#account-invite=\(Fixtures.invitationCode)"))
        #expect(throws: AccountError.invalidInput(.invitationCode)) {
            try AccountInvitationCode(link: link, origin: origin)
        }
    }
}

enum InvitationOperation: CaseIterable, Sendable {
    case load, create, revoke

    var method: String {
        switch self {
        case .load: "GET"
        case .create: "POST"
        case .revoke: "DELETE"
        }
    }

    var path: String {
        let base = "/api/account/households/\(Fixtures.householdID)"
        switch self {
        case .load: return base
        case .create: return "\(base)/invitations"
        case .revoke: return "\(base)/invitations/\(Fixtures.invitationID.uuidString.lowercased())"
        }
    }

    func response() throws -> HTTPResponse {
        switch self {
        case .load: try Fixtures.response(Fixtures.invitationAccess())
        case .create: try Fixtures.response(Fixtures.createdInvitation(), status: 201)
        case .revoke: try Fixtures.response(Fixtures.invitationAccess(invitations: [Fixtures.invitation(revoked: true)]))
        }
    }

    func perform(_ session: AccountSession) async throws {
        switch self {
        case .load: _ = try await session.loadInvitations(householdID: Fixtures.invitedHouseholdID)
        case .create: _ = try await session.createInvitation(householdID: Fixtures.invitedHouseholdID, version: 17)
        case .revoke:
            _ = try await session.revokeInvitation(id: Fixtures.invitationID, householdID: Fixtures.invitedHouseholdID, version: 17)
        }
    }
}

extension Fixtures {
    static let invitedHouseholdID = UUID(uuidString: householdID)!
    static let invitationID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    static func invitation(revoked: Bool = false, uses: Int64 = 0) -> [String: JSONValue] {
        [
            "id": .string(invitationID.uuidString.lowercased()),
            "createdAt": .string("2026-09-13T12:00:00.000Z"),
            "expiresAt": .string("2026-09-20T12:00:00Z"),
            "revokedAt": revoked ? .string("2026-09-13T13:00:00.000Z") : .null,
            "uses": .integer(uses)
        ]
    }

    static func invitationAccess(
        version: Int64 = 18, role: String = "owner", invitations: [[String: JSONValue]]? = nil
    ) -> [String: JSONValue] {
        var household = try! HouseholdFields(Self.household).object
        household["version"] = .integer(version)
        return [
            "household": .object(household), "memberId": .string(memberID), "role": .string(role),
            "invitations": .array((invitations ?? [invitation()]).map(JSONValue.object))
        ]
    }

    static func createdInvitation() -> [String: JSONValue] {
        ["code": .string(invitationCode), "invitation": .object(invitation()), "access": .object(invitationAccess())]
    }
}
