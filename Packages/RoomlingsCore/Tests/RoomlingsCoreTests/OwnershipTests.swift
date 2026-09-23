import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native household ownership", .timeLimit(.minutes(1)))
struct OwnershipTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let accountID = UUID(uuidString: Fixtures.accountID)!
    private let successorID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    @Test
    func theRosterOnlyOffersActiveAccountLinkedPeersToTheOwner() throws {
        let access = try decode(access())
        #expect(access.ownershipCandidates.map(\.id) == [successorID])
        #expect(access.members.count == 4)
        #expect(try decode(self.access(transferred: true)).ownershipCandidates.isEmpty)
    }

    @Test(arguments: [
        "missing-roster", "duplicate", "missing-member", "foreign-member", "wrong-name", "wrong-role",
        "actor-unlinked", "actor-inactive", "inactive-owner", "two-owners", "missing-linked", "invalid-linked"
    ])
    func rejectsInconsistentOrIncompleteMemberRosters(fault: String) throws {
        var fields = access()
        var members = try HouseholdFields(.object(fields)).array("members").map { try HouseholdFields($0).object }
        switch fault {
        case "missing-roster": fields.removeValue(forKey: "members")
        case "duplicate": members.append(members[0])
        case "missing-member": members.removeLast()
        case "foreign-member": members[1]["memberId"] = .string(UUID().uuidString)
        case "wrong-name": members[1]["name"] = .string("Unrelated roommate")
        case "wrong-role": fields["role"] = .string("admin")
        case "actor-unlinked": members[0]["linked"] = .bool(false)
        case "actor-inactive": members[0]["active"] = .bool(false)
        case "inactive-owner":
            members[0]["role"] = .string("member")
            fields["role"] = .string("member")
            fields["invitations"] = .array([])
            members[3]["role"] = .string("owner")
        case "two-owners": members[1]["role"] = .string("owner")
        case "missing-linked": members[1].removeValue(forKey: "linked")
        default: members[1]["linked"] = .integer(1)
        }
        if fault != "missing-roster" { fields["members"] = .array(members.map(JSONValue.object)) }
        #expect(throws: (any Error).self) { try decode(fields) }
    }

    @Test
    func transferUsesTheNativeVersionedEndpointAndUpdatesTheMembershipRole() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(state()), try Fixtures.response(access(transferred: true))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        let result = try await transfer(session)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/account/households/\(Fixtures.householdID)/owner")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)"
        #expect(authenticated)
        #expect(!request.httpShouldHandleCookies)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object(["memberId": .string(successorID.uuidString.lowercased()), "version": .integer(17)]))
        #expect(result.role == .member)
        let after = try #require(await session.state)
        #expect(after.memberships.first?.role == .member)
        #expect(after.session?.memberID == before.session?.memberID)
        #expect(after.account == before.account)
        #expect(after.devices == before.devices)
        #expect(after.session?.household.version == 18)
        for key in ["expenses", "settlements", "unrecognizedServerField"] {
            #expect(after.session?.household.value[key] == before.session?.household.value[key])
        }
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.saveAttempts == 0)
        #expect(await credentials.clearAttempts == 0)
    }

    @Test
    func refreshingHouseholdAccessUpdatesARoleChangedOnAnotherDevice() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(state()), try Fixtures.response(access(transferred: true))
        ])
        let session = make(transport)
        try await session.restore()
        let result = try await session.loadHouseholdAccess(householdID: householdID)
        #expect(result.role == .member)
        #expect(await session.state?.memberships.first?.role == .member)
        await #expect(throws: AccountError.accountStateRequired) { try await transfer(session, version: 18) }
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: ["admin", "member", "signed-out", "deleting", "wrong-account", "wrong-home", "self", "absent", "inactive", "stale"])
    func invalidContextsCannotStartAHandoff(kind: String) async throws {
        var fields = state()
        var memberID = successorID
        var expectedAccount = accountID
        var expectedHome = householdID
        var version: Int64 = 17
        switch kind {
        case "admin", "member":
            var membership = try HouseholdFields(Fixtures.membership).object
            membership["role"] = .string(kind)
            fields["memberships"] = .array([.object(membership)])
        case "signed-out": fields = Fixtures.state(signedIn: false)
        case "deleting": fields = Fixtures.state(deletionPending: true)
        case "wrong-account": expectedAccount = UUID()
        case "wrong-home": expectedHome = UUID()
        case "self": memberID = UUID(uuidString: Fixtures.memberID)!
        case "absent": memberID = UUID()
        case "inactive": memberID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        default: version = 16
        }
        let transport = TestTransport(response: try Fixtures.response(fields))
        let session = make(transport)
        let before = try await session.restore()
        await #expect(throws: AccountError.self) {
            try await session.transferOwnership(to: memberID, householdID: expectedHome, version: version, accountID: expectedAccount)
        }
        #expect(await transport.requests.count == 1)
        #expect(await session.state == before)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ["version", "still-owner", "other-owner", "member", "foreign-home", "credential"])
    func unconfirmedResponsesCannotChangeLocalOwnership(fault: String) async throws {
        var fields = access(transferred: true)
        switch fault {
        case "version":
            var home = household()
            home["version"] = .integer(17)
            fields["household"] = .object(home)
        case "still-owner": fields = access()
        case "other-owner":
            var members = try HouseholdFields(.object(fields)).array("members").map { try HouseholdFields($0).object }
            members[1]["role"] = .string("member")
            members[2]["role"] = .string("owner")
            members[2]["linked"] = .bool(true)
            fields["members"] = .array(members.map(JSONValue.object))
        case "member": fields["memberId"] = .string(successorID.uuidString)
        case "foreign-home":
            var home = household()
            home["id"] = .string(UUID().uuidString)
            fields["household"] = .object(home)
        default: fields["accessToken"] = .string(Fixtures.newToken.value)
        }
        let transport = TestTransport(responses: [try Fixtures.response(state()), try Fixtures.response(fields)])
        let session = make(transport)
        let before = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await transfer(session) }
        #expect(await session.state == before)
    }

    @Test(arguments: [400, 403, 409, 429, 503])
    func rejectedTransfersPreserveCredentialsAndDoNotRetry(status: Int) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(state()), try Fixtures.failure(status: status, code: nil)
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        await #expect(throws: AccountError.server(status: status, code: nil)) { try await transfer(session) }
        #expect(await session.state == before)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: ["cancel", "replacement", "expiry-replacement", "expiry"])
    func delayedResponsesCannotEscapeTheAccountGateOrOverwriteNewerCredentials(kind: String) async throws {
        let started = Signal()
        let finish = Signal()
        let original = try Fixtures.response(state())
        let result = kind.hasPrefix("expiry")
            ? try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
            : try Fixtures.response(access(transferred: true))
        let transport = TestTransport { _, index in
            if index == 0 { return original }
            await started.signal()
            await finish.wait()
            return result
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        let pending = Task { try await transfer(session) }
        await started.wait()
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        await #expect(throws: AccountError.operationInProgress) { try await session.loadHouseholdAccess(householdID: householdID) }
        if kind == "cancel" { pending.cancel() }
        if kind.contains("replacement") { await credentials.replaceToken(Fixtures.newToken) }
        await finish.signal()
        if kind == "cancel" {
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else if kind.contains("replacement") {
            await #expect(throws: AccountError.accountStateRequired) { try await pending.value }
        } else {
            await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await pending.value }
        }
        #expect(await session.state == (kind == "expiry" ? nil : before))
        #expect(await credentials.clearAttempts == (kind == "expiry" ? 1 : 0))
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.isBusy == false)
    }

    private func household(version: Int64 = 17) -> [String: JSONValue] {
        var result = try! HouseholdFields(Fixtures.household).object
        result["version"] = .integer(version)
        result["members"] = .array([
            .object(["id": .string(Fixtures.memberID), "name": .string("Roommate"), "color": .string("#7d9070")]),
            .object(["id": .string(successorID.uuidString), "name": .string("Sam"), "color": .string("#81b29a")]),
            .object(["id": .string("66666666-6666-4666-8666-666666666666"), "name": .string("Browser roommate"), "color": .string("#81b29a")]),
            .object(["id": .string("77777777-7777-4777-8777-777777777777"), "name": .string("Former roommate"), "color": .string("#81b29a"), "inactive": .bool(true)])
        ])
        return result
    }

    private func state() -> [String: JSONValue] {
        var result = Fixtures.state(selectedHousehold: true)
        result["session"] = .object(["token": .null, "memberId": .string(Fixtures.memberID), "household": .object(household())])
        return result
    }

    private func access(transferred: Bool = false) -> [String: JSONValue] {
        let home = household(version: transferred ? 18 : 17)
        let roster = home["members"]!.arrayValue!.enumerated().map { index, member -> JSONValue in
            .object([
                "memberId": member["id"]!, "name": member["name"]!,
                "role": .string(index == (transferred ? 1 : 0) ? "owner" : index == 1 ? "admin" : "member"),
                "linked": .bool(index != 2), "active": .bool(index != 3)
            ])
        }
        return ["household": .object(home), "memberId": .string(Fixtures.memberID),
                "role": .string(transferred ? "member" : "owner"),
                "invitations": .array([]), "members": .array(roster)]
    }

    private func decode(_ value: [String: JSONValue]) throws -> HouseholdInvitationAccess {
        try JSONDecoder().decode(HouseholdInvitationAccess.self, from: Fixtures.data(value))
    }

    private func transfer(_ session: AccountSession, version: Int64 = 17) async throws -> HouseholdInvitationAccess {
        try await session.transferOwnership(to: successorID, householdID: householdID, version: version, accountID: accountID)
    }

    private func make(_ transport: TestTransport, _ credentials: MemoryTokenStore? = nil) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration,
                       tokenStore: credentials ?? MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}
