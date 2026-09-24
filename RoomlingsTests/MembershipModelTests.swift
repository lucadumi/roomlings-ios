import XCTest
import RoomlingsCore
@testable import Roomlings

@MainActor
final class MembershipModelTests: XCTestCase {
    private let fixture = InvitationModelFixture()
    private let accountID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let peerID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    func testLeavingKeepsTheAccountAndOtherHouseholdsButClearsTheRoom() async throws {
        let (model, _, credentials) = try await make([access(role: "member"), state(departed: true)])
        let loaded = await model.loadHouseholdAccess()
        XCTAssertTrue(loaded)
        let previous = model.state
        let token = await credentials.read()
        let left = await model.leaveHousehold(householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertTrue(left)
        XCTAssertTrue(model.signedIn)
        XCTAssertTrue(model.canUseAccount)
        XCTAssertEqual(model.state?.account, previous?.account)
        XCTAssertEqual(model.state?.memberships.map(\.householdID), [fixture.otherHouseholdID])
        XCTAssertNil(model.state?.session)
        XCTAssertNil(model.room.householdID)
        XCTAssertNil(model.ledger)
        XCTAssertNil(model.shopping)
        XCTAssertNil(model.invitations)
        XCTAssertFalse(model.membershipNeedsRefresh)
        XCTAssertEqual(model.notice, "You left the household. Shared debts and history remain.")
        let after = await credentials.read()
        XCTAssertEqual(after, token)
    }

    func testASoleOwnerCanCloseHouseholdAccessWithoutDeletingTheAccount() async throws {
        let (model, _, _) = try await make([
            fixture.state(), fixture.access(version: 17), fixture.state(selectedHousehold: false)
        ])
        _ = await model.refresh()
        _ = await model.loadHouseholdAccess()
        XCTAssertTrue(model.invitations?.canLeave == true)
        let left = await model.leaveHousehold(householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertTrue(left)
        XCTAssertTrue(model.signedIn)
        XCTAssertEqual(model.deletionStatus, .none)
        XCTAssertTrue(model.state?.memberships.isEmpty == true)
    }

    func testAnOwnerWithOtherRoommatesMustHandOffBeforeLeaving() async throws {
        let (model, transport, _) = try await make([access(role: "owner")], role: "owner")
        _ = await model.loadHouseholdAccess()
        let left = await model.leaveHousehold(householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertFalse(left)
        XCTAssertTrue(model.message?.contains("Transfer ownership") == true)
        XCTAssertFalse(model.membershipNeedsRefresh)
        XCTAssertNotNil(model.room.householdID)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testTheOwnerCanRemoveBrowserOnlyAccessWithoutRemovingTheIdentityFromHistory() async throws {
        let (model, _, _) = try await make([
            access(role: "owner", linked: false), access(role: "owner", removed: true, version: 18)
        ], role: "owner")
        _ = await model.loadHouseholdAccess()
        XCTAssertEqual(model.invitations?.removalCandidates.map(\.id), [peerID])
        let removed = await model.removeHouseholdMember(id: peerID, householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertTrue(removed)
        XCTAssertEqual(model.invitations?.members.first { $0.id == peerID }?.active, false)
        XCTAssertEqual(model.invitations?.members.count, 2)
        XCTAssertEqual(model.state?.session?.household.id, fixture.householdID)
        XCTAssertEqual(model.state?.memberships.first?.role, .owner)
        XCTAssertEqual(model.notice, "Roommate access removed. Shared debts and history kept.")
    }

    func testAnUnconfirmedRemovalCannotBeRepeatedBeforeRefreshingTheRoster() async throws {
        let (model, transport, _) = try await make([
            access(role: "owner"), fixture.failure(503), access(role: "owner", removed: true, version: 18)
        ], role: "owner")
        _ = await model.loadHouseholdAccess()
        let removed = await model.removeHouseholdMember(id: peerID, householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertFalse(removed)
        XCTAssertTrue(model.invitationNeedsRefresh)
        XCTAssertNil(model.notice)
        let repeated = await model.removeHouseholdMember(id: peerID, householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertFalse(repeated)
        let loaded = await model.loadHouseholdAccess()
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.invitations?.members.first { $0.id == peerID }?.active, false)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    func testAnUncertainLeaveClosesToolsUntilTheAccountRefreshConfirmsAccess() async throws {
        let (model, transport, _) = try await make([
            access(role: "member"), fixture.failure(500), state(departed: true)
        ])
        _ = await model.loadHouseholdAccess()
        let left = await model.leaveHousehold(householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertFalse(left)
        XCTAssertTrue(model.signedIn)
        XCTAssertTrue(model.membershipNeedsRefresh)
        XCTAssertFalse(model.canUseAccount)
        XCTAssertNil(model.room.householdID)
        XCTAssertNil(model.ledger)
        XCTAssertNil(model.notice)
        let selected = await model.select(id: fixture.otherHouseholdID)
        XCTAssertFalse(selected)
        let refreshed = await model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(model.membershipNeedsRefresh)
        XCTAssertTrue(model.canUseAccount)
        XCTAssertEqual(model.state?.memberships.map(\.householdID), [fixture.otherHouseholdID])
        XCTAssertEqual(model.notice, "You no longer have access to that household. Shared debts and history remain.")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testStaleConfirmationsCannotChangeMembership() async throws {
        let (model, transport, _) = try await make([access(role: "owner"), state(role: "owner", version: 18)], role: "owner")
        _ = await model.loadHouseholdAccess()
        let wrongAccount = await model.removeHouseholdMember(
            id: peerID, householdID: fixture.householdID, version: 17, accountID: UUID()
        )
        XCTAssertFalse(wrongAccount)
        _ = await model.refresh()
        let stale = await model.removeHouseholdMember(id: peerID, householdID: fixture.householdID, version: 17, accountID: accountID)
        XCTAssertFalse(stale)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testMembersAndAdminsCannotRemoveOtherRoommates() async throws {
        for role in ["member", "admin"] {
            let (model, transport, _) = try await make([access(role: role)], role: role)
            _ = await model.loadHouseholdAccess()
            let removed = await model.removeHouseholdMember(id: peerID, householdID: fixture.householdID, version: 17, accountID: accountID)
            XCTAssertFalse(removed)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    private var otherMembership: [String: Any] {
        ["householdId": fixture.otherHouseholdID.uuidString, "memberId": "77777777-7777-4777-8777-777777777777",
         "householdName": "Other home", "currency": "EUR", "role": "member"]
    }

    private func household(version: Int = 17, removed: Bool = false) -> [String: Any] {
        var home = fixture.household(id: fixture.householdID, version: version)
        home["members"] = [
            ["id": fixture.memberID, "name": "Ada", "color": "#81b29a"],
            ["id": peerID.uuidString, "name": "Sam", "color": "#81b29a", "inactive": removed]
        ]
        return home
    }

    private func state(role: String = "member", version: Int = 17, departed: Bool = false) throws -> HTTPResponse {
        let base = try fixture.state(version: version, household: household(version: version), selectedHousehold: !departed)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: base.data) as? [String: Any])
        fields["memberships"] = departed ? [otherMembership] : [
            ["householdId": fixture.householdID.uuidString, "memberId": fixture.memberID, "householdName": "Our home",
             "currency": "EUR", "role": role], otherMembership
        ]
        return try response(fields)
    }

    private func access(role: String, linked: Bool = true, removed: Bool = false, version: Int = 17) throws -> HTTPResponse {
        try response([
            "household": household(version: version, removed: removed), "memberId": fixture.memberID, "role": role,
            "members": [
                ["memberId": fixture.memberID, "name": "Ada", "role": role, "linked": true, "active": true],
                ["memberId": peerID.uuidString, "name": "Sam", "role": role == "owner" ? "member" : "owner",
                 "linked": linked && !removed, "active": !removed]
            ],
            "invitations": []
        ])
    }

    private func response(_ fields: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(data: try JSONSerialization.data(withJSONObject: fields), statusCode: 200, url: fixture.api.origin)
    }

    private func make(_ responses: [HTTPResponse], role: String = "member") async throws
        -> (AccountModel, InvitationModelTransport, InvitationModelStore) {
        let transport = InvitationModelTransport(responses: try [state(role: role)] + responses, holdIndex: nil)
        let credentials = InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let client = AccountSession(configuration: fixture.api, tokenStore: credentials, transport: transport)
        let model = AccountModel(client: client)
        await model.start()
        return (model, transport, credentials)
    }
}
