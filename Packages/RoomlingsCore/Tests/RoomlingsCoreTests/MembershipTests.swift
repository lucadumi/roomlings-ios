import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native household membership", .timeLimit(.minutes(1)))
struct MembershipTests {
    @Test(arguments: MembershipOperation.allCases)
    func usesTheVersionedNativeRouteAndPreservesTheAccount(operation: MembershipOperation) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(operation)),
            try Fixtures.response(MembershipFixtures.result(operation))
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        try await operation.perform(session)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == operation.path)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)"
        #expect(authenticated)
        #expect(!request.httpShouldHandleCookies)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        #expect(try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) == .object(["version": .integer(17)]))
        let after = try #require(await session.state)
        #expect(after.account == before.account)
        #expect(after.devices == before.devices)
        #expect(after.isSignedIn)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.pendingHouseholdDeparture == nil)
        if operation == .leave {
            #expect(after.session == nil)
            #expect(after.memberships == before.memberships.filter { $0.householdID != MembershipFixtures.home })
        } else {
            #expect(after.session?.household.version == 18)
            #expect(after.memberships == before.memberships)
            #expect(after.session?.household.value["expenses"] == before.session?.household.value["expenses"])
            #expect(after.session?.household.value["settlements"] == before.session?.household.value["settlements"])
        }
    }

    @Test
    func theRosterPermitsBrowserOnlyRemovalButRequiresOwnerHandoffBeforeLeaving() throws {
        var fields = MembershipFixtures.access()
        var members = try HouseholdFields(.object(fields)).array("members").map { try HouseholdFields($0).object }
        members[1]["linked"] = .bool(false)
        fields["members"] = .array(members.map(JSONValue.object))
        let owner = try JSONDecoder().decode(HouseholdInvitationAccess.self, from: Fixtures.data(fields))
        #expect(owner.removalCandidates.map(\.id) == [MembershipFixtures.peer])
        #expect(owner.ownershipCandidates.isEmpty)
        #expect(!owner.canLeave)
        let soleOwner = try JSONDecoder().decode(HouseholdInvitationAccess.self, from: Fixtures.data(MembershipFixtures.access(removed: true)))
        #expect(soleOwner.canLeave)
        #expect(soleOwner.removalCandidates.isEmpty)
        members[1]["active"] = .bool(false)
        fields["members"] = .array(members.map(JSONValue.object))
        let disabledAccount = try JSONDecoder().decode(HouseholdInvitationAccess.self, from: Fixtures.data(fields))
        #expect(!disabledAccount.canLeave, "Match the server's raw roster check even during another account's pending deletion.")
    }

    @Test(arguments: MembershipOperation.allCases, ["unrestored", "signed-out", "wrong-account", "wrong-home", "stale", "missing-token"])
    func rejectsStaleOrUnconfirmedContextsBeforeSending(operation: MembershipOperation, fault: String) async throws {
        let fields = fault == "signed-out" ? Fixtures.state(signedIn: false) : MembershipFixtures.state(operation)
        let transport = TestTransport(response: try Fixtures.response(fields))
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        if fault != "unrestored" { try await session.restore() }
        if fault == "missing-token" { await credentials.replaceToken(nil) }
        await #expect(throws: AccountError.self) {
            try await operation.perform(session, householdID: fault == "wrong-home" ? UUID() : MembershipFixtures.home,
                                        accountID: fault == "wrong-account" ? UUID() : MembershipFixtures.account,
                                        version: fault == "stale" ? 16 : 17)
        }
        #expect(await transport.requests.count == (fault == "unrestored" ? 0 : 1))
        #expect(await session.pendingHouseholdDeparture == nil)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: ["member", "admin", "self", "missing", "inactive"])
    func removalRequiresTheOwnerAndAnotherActiveMember(fault: String) async throws {
        var fields = MembershipFixtures.state(.remove)
        var target = MembershipFixtures.peer
        if ["member", "admin"].contains(fault) {
            var membership = try HouseholdFields(Fixtures.membership).object
            membership["role"] = .string(fault)
            fields["memberships"] = .array([.object(membership), MembershipFixtures.otherMembership])
        } else if fault == "self" {
            target = UUID(uuidString: Fixtures.memberID)!
        } else if fault == "missing" {
            target = UUID()
        } else {
            fields["session"] = .object([
                "token": .null, "memberId": .string(Fixtures.memberID),
                "household": .object(MembershipFixtures.household(removed: true))
            ])
        }
        let transport = TestTransport(response: try Fixtures.response(fields))
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.self) {
            try await session.removeHouseholdMember(id: target, householdID: MembershipFixtures.home, version: 17,
                                                    accountID: MembershipFixtures.account)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: MembershipOperation.allCases, [400, 403, 404, 409, 429, 503])
    func failuresKeepCredentialsAndNeverAutomaticallyRepeatTheChange(operation: MembershipOperation, status: Int) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(operation)), try Fixtures.failure(status: status, code: nil)
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        await #expect(throws: AccountError.server(status: status, code: nil)) { try await operation.perform(session) }
        #expect(await session.state == before)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await transport.requests.count == 2)
        let needsRefresh = operation == .leave && ([403, 404].contains(status) || status >= 500)
        #expect(await session.pendingHouseholdDeparture == (needsRefresh ? MembershipFixtures.home : nil))
    }

    @Test(arguments: ["signed-out", "still-member", "selected-other", "other-account", "other-device", "credential"])
    func leavingMustConfirmTheSameAccountWithoutTheDepartedMembership(fault: String) async throws {
        var result = MembershipFixtures.result(.leave)
        switch fault {
        case "signed-out": result = Fixtures.state(signedIn: false)
        case "still-member": result["memberships"] = .array([Fixtures.membership, MembershipFixtures.otherMembership])
        case "selected-other":
            var home = MembershipFixtures.household()
            home["id"] = .string(MembershipFixtures.otherHome.uuidString)
            home["name"] = .string("Other home")
            home["members"] = .array([.object([
                "id": MembershipFixtures.otherMembership["memberId"]!, "name": .string("Roommate"), "color": .string("#81b29a")
            ])])
            result["session"] = .object([
                "token": .null, "memberId": MembershipFixtures.otherMembership["memberId"]!, "household": .object(home)
            ])
        case "other-account":
            var account = try HouseholdFields(Fixtures.account).object
            account["id"] = .string(UUID().uuidString)
            result["account"] = .object(account)
        case "other-device":
            var device = try HouseholdFields(Fixtures.device).object
            device["id"] = .string(UUID().uuidString)
            result["devices"] = .array([.object(device)])
        default: result["accessToken"] = .string(Fixtures.newToken.value)
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(.leave)), try Fixtures.response(result)
        ])
        let session = make(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await MembershipOperation.leave.perform(session) }
        #expect(await session.state == original)
        #expect(await session.pendingHouseholdDeparture == MembershipFixtures.home)
        #expect(await session.selectedHousehold == nil)
    }

    @Test(arguments: ["active", "active-projection", "missing", "wrong-version", "lost-ownership", "changed-ledger"])
    func removalMustConfirmAStillRetainedInactiveMember(fault: String) async throws {
        var result = MembershipFixtures.access(removed: true, version: 18)
        switch fault {
        case "active": result = MembershipFixtures.access(version: 18)
        case "active-projection": result["household"] = .object(MembershipFixtures.household(version: 18))
        case "missing":
            result["members"] = .array([try HouseholdFields(.object(result)).array("members")[0]])
        case "wrong-version": result = MembershipFixtures.access(removed: true)
        case "changed-ledger":
            var home = MembershipFixtures.household(removed: true, version: 18)
            home["expenses"] = .array([])
            result["household"] = .object(home)
        default: result["role"] = .string("member")
        }
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(.remove)), try Fixtures.response(result)
        ])
        let session = make(transport)
        let original = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await MembershipOperation.remove.perform(session) }
        #expect(await session.state == original)
    }

    @Test
    func aLostLeaveResponseClosesHouseholdActionsUntilRefreshResolvesAccess() async throws {
        let transport = TestTransport { request, index in
            if index == 0 { return try Fixtures.response(MembershipFixtures.state(.leave)) }
            if request.httpMethod == "DELETE" { throw URLError(.networkConnectionLost) }
            return try Fixtures.response(MembershipFixtures.result(.leave))
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let before = try await session.restore()
        await #expect(throws: AccountError.network(code: URLError.networkConnectionLost.rawValue)) {
            try await MembershipOperation.leave.perform(session)
        }
        #expect(await session.selectedHousehold == nil)
        await #expect(throws: AccountError.accountStateRequired) { try await MembershipOperation.leave.perform(session) }
        await #expect(throws: AccountError.accountStateRequired) { try await session.selectHousehold(id: MembershipFixtures.otherHome) }
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.recordAnalytics(AnalyticsEvent(kind: .appOpened, at: .now), context: AnalyticsContext(state: before))
        }
        let next = try await session.restore()
        #expect(next.isSignedIn)
        #expect(next.memberships.map(\.householdID) == [MembershipFixtures.otherHome])
        #expect(await session.pendingHouseholdDeparture == nil)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test(arguments: MembershipOperation.allCases, ["cancelled", "replacement", "expired", "expired-replacement"])
    func suspendedChangesRemainSerializedAndCannotEraseNewCredentials(operation: MembershipOperation, fault: String) async throws {
        let started = Signal()
        let finish = Signal()
        let initial = try Fixtures.response(MembershipFixtures.state(operation))
        let response = fault.hasPrefix("expired") ? try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
            : try Fixtures.response(MembershipFixtures.result(operation))
        let transport = TestTransport { _, index in
            if index == 0 { return initial }
            await started.signal()
            await finish.wait()
            return response
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        let original = try await session.restore()
        let pending = Task { try await operation.perform(session) }
        await started.wait()
        await #expect(throws: AccountError.operationInProgress) { try await session.restore() }
        await #expect(throws: AccountError.operationInProgress) { try await session.logout() }
        if fault == "cancelled" { pending.cancel() }
        if fault.contains("replacement") { await credentials.replaceToken(Fixtures.newToken) }
        await finish.signal()
        if fault == "cancelled" {
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else if fault.contains("replacement") {
            await #expect(throws: AccountError.accountStateRequired) { try await pending.value }
        } else {
            await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await pending.value }
        }
        #expect(await session.state == (fault == "expired" ? nil : original))
        #expect(await credentials.clearAttempts == (fault == "expired" ? 1 : 0))
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test
    func aKnownDeletionBarrierDoesNotPreventAnExplicitDeletionOnlyRetry() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(.leave)),
            try Fixtures.failure(status: 503, code: "ACCOUNT_DELETION_PENDING"),
            try Fixtures.response(Fixtures.state(signedIn: false))
        ])
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.server(status: 503, code: .accountDeletionPending)) {
            try await MembershipOperation.leave.perform(session)
        }
        #expect(await session.pendingHouseholdDeparture == nil)
        #expect(await session.deletionStatus == .pending)
        try await session.deleteAccount(accountID: MembershipFixtures.account, confirmation: "roommate@example.com")
        #expect(await session.deletionStatus == .completed)
    }

    @Test
    func aFailedStatusRefreshCannotReopenAnUncertainDeparture() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(MembershipFixtures.state(.leave)),
            try Fixtures.failure(status: 500, code: nil), try Fixtures.failure(status: 500, code: nil),
            try Fixtures.response(MembershipFixtures.state(.leave))
        ])
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.self) { try await MembershipOperation.leave.perform(session) }
        await #expect(throws: AccountError.self) { try await session.restore() }
        #expect(await session.pendingHouseholdDeparture == MembershipFixtures.home)
        #expect(await session.selectedHousehold == nil)
        try await session.restore()
        #expect(await session.pendingHouseholdDeparture == nil)
        #expect(await session.selectedHousehold?.id == MembershipFixtures.home)
    }

    @Test(arguments: [false, true])
    func anExpiredStatusRefreshCannotEraseAReplacementCredential(replaced: Bool) async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport { _, index in
            if index == 0 { return try Fixtures.response(MembershipFixtures.state(.leave)) }
            if index == 1 { return try Fixtures.failure(status: 500, code: nil) }
            await started.signal()
            await finish.wait()
            return try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = make(transport, credentials)
        try await session.restore()
        await #expect(throws: AccountError.self) { try await MembershipOperation.leave.perform(session) }
        let refresh = Task { try await session.restore() }
        await started.wait()
        if replaced { await credentials.replaceToken(Fixtures.newToken) }
        await finish.signal()
        let expected: AccountError = replaced ? .accountStateRequired : .server(status: 401, code: .accountSessionRequired)
        await #expect(throws: expected) { try await refresh.value }
        #expect(await credentials.clearAttempts == (replaced ? 0 : 1))
        #expect(await credentials.token == (replaced ? Fixtures.newToken : nil))
    }

    @Test
    func anUnincrementableVersionCannotLeaveAnUnconfirmedDepartureMarker() async throws {
        var fields = MembershipFixtures.state(.leave)
        fields["session"] = .object([
            "token": .null, "memberId": .string(Fixtures.memberID),
            "household": .object(MembershipFixtures.household(version: HouseholdValidation.maximumInteger))
        ])
        let transport = TestTransport(response: try Fixtures.response(fields))
        let session = make(transport)
        try await session.restore()
        await #expect(throws: AccountError.invalidInput(.version)) {
            try await MembershipOperation.leave.perform(session, version: HouseholdValidation.maximumInteger)
        }
        #expect(await session.pendingHouseholdDeparture == nil)
        #expect(await transport.requests.count == 1)
    }

    private func make(_ transport: TestTransport, _ credentials: MemoryTokenStore? = nil) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration,
                       tokenStore: credentials ?? MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}

enum MembershipOperation: CaseIterable, Sendable {
    case leave, remove

    var path: String {
        let base = "/api/account/households/\(Fixtures.householdID)"
        return self == .leave ? "\(base)/membership" : "\(base)/members/\(MembershipFixtures.peer.uuidString.lowercased())"
    }

    func perform(_ session: AccountSession, householdID: UUID = MembershipFixtures.home,
                 accountID: UUID = MembershipFixtures.account, version: Int64 = 17) async throws {
        switch self {
        case .leave: _ = try await session.leaveHousehold(householdID: householdID, version: version, accountID: accountID)
        case .remove:
            _ = try await session.removeHouseholdMember(id: MembershipFixtures.peer, householdID: householdID,
                                                       version: version, accountID: accountID)
        }
    }
}

private enum MembershipFixtures {
    static let home = UUID(uuidString: Fixtures.householdID)!
    static let account = UUID(uuidString: Fixtures.accountID)!
    static let peer = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let otherHome = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static var otherMembership: JSONValue {
        .object([
            "householdId": .string(otherHome.uuidString), "householdName": .string("Other home"),
            "memberId": .string("77777777-7777-4777-8777-777777777777"), "currency": .string("EUR"), "role": .string("member")
        ])
    }

    static func household(removed: Bool = false, version: Int64 = 17) -> [String: JSONValue] {
        var home = try! HouseholdFields(Fixtures.household).object
        home["version"] = .integer(version)
        home["members"] = .array([
            .object(["id": .string(Fixtures.memberID), "name": .string("Roommate"), "color": .string("#81b29a")]),
            .object(["id": .string(peer.uuidString), "name": .string("Sam"), "color": .string("#81b29a"), "inactive": .bool(removed)])
        ])
        return home
    }

    static func state(_ operation: MembershipOperation) -> [String: JSONValue] {
        var fields = Fixtures.state(selectedHousehold: true)
        var membership = try! HouseholdFields(Fixtures.membership).object
        membership["role"] = .string(operation == .leave ? "member" : "owner")
        fields["memberships"] = .array([.object(membership), otherMembership])
        fields["session"] = .object(["token": .null, "memberId": .string(Fixtures.memberID), "household": .object(household())])
        return fields
    }

    static func access(removed: Bool = false, version: Int64 = 17) -> [String: JSONValue] {
        [
            "household": .object(household(removed: removed, version: version)),
            "memberId": .string(Fixtures.memberID), "role": .string("owner"), "invitations": .array([]),
            "members": .array([
                .object(["memberId": .string(Fixtures.memberID), "name": .string("Roommate"),
                         "role": .string("owner"), "linked": .bool(true), "active": .bool(true)]),
                .object(["memberId": .string(peer.uuidString), "name": .string("Sam"),
                         "role": .string("member"), "linked": .bool(false), "active": .bool(!removed)])
            ])
        ]
    }

    static func result(_ operation: MembershipOperation) -> [String: JSONValue] {
        if operation == .remove { return access(removed: true, version: 18) }
        var fields = state(.leave)
        fields["session"] = .null
        fields["memberships"] = .array([otherMembership])
        return fields
    }
}
