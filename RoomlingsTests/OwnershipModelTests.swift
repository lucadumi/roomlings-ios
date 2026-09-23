import XCTest
import SwiftUI
import RoomlingsCore
@testable import Roomlings

@MainActor
final class OwnershipModelTests: XCTestCase {
    private let fixture = InvitationModelFixture()
    private let accountID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let successorID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    func testMembersAndOwnershipLoadWithoutAnInvitationDomain() async throws {
        let (model, _) = try await make([access()])
        let loaded = await model.loadHouseholdAccess()
        XCTAssertTrue(loaded)
        XCTAssertNotNil(model.invitationSetupError)
        XCTAssertEqual(model.invitations?.ownershipCandidates.map(\.id), [successorID])
        XCTAssertEqual(model.invitations?.members.map(\.name), ["Ada", "Sam"])
        XCTAssertEqual(model.state?.memberships.first?.role, .owner)
    }

    func testConfirmedTransferClearsTheShareLinkAndPublishesTheNewRole() async throws {
        let created = try response([
            "code": fixture.code, "invitation": fixture.invitation(), "access": accessFields(version: 18)
        ], status: 201)
        let (model, transport) = try await make([created, access(version: 19, transferred: true)], invitationOrigin: fixture.origin)
        let added = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(added)
        XCTAssertNotNil(model.invitationLink)
        let ledger = model.ledger
        let transferred = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 18, accountID: accountID
        )
        XCTAssertTrue(transferred)
        XCTAssertEqual(model.state?.memberships.first?.role, .member)
        XCTAssertEqual(model.invitations?.role, .member)
        XCTAssertTrue(model.invitations?.invitations.isEmpty == true)
        XCTAssertTrue(model.invitations?.ownershipCandidates.isEmpty == true)
        XCTAssertNil(model.invitationLink)
        XCTAssertFalse(model.invitationNeedsRefresh)
        XCTAssertEqual(model.ledger?.expenses, ledger?.expenses)
        XCTAssertEqual(model.notice, "Ownership transferred. You are still a household member.")
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.url?.path, "/api/account/households/\(fixture.householdID.uuidString.lowercased())/owner")
    }

    func testAnUncertainTransferCannotBeRepeatedBeforeRefreshingMembers() async throws {
        let (model, transport) = try await make([access(), fixture.failure(503), access(version: 18, transferred: true)])
        _ = await model.loadHouseholdAccess()
        let transferred = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 17, accountID: accountID
        )
        XCTAssertFalse(transferred)
        XCTAssertTrue(model.invitationNeedsRefresh)
        XCTAssertNil(model.notice)
        let retry = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 17, accountID: accountID
        )
        XCTAssertFalse(retry)
        let beforeRefresh = await transport.requests
        XCTAssertEqual(beforeRefresh.count, 3)
        let refreshed = await model.loadHouseholdAccess()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.invitations?.role, .member)
        XCTAssertFalse(model.invitationNeedsRefresh)
        XCTAssertNil(model.notice)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testAStaleOrDifferentAccountConfirmationNeverSendsTheTransfer() async throws {
        let (model, transport) = try await make([access(), state(version: 18)])
        _ = await model.loadHouseholdAccess()
        let wrongAccount = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 17, accountID: UUID()
        )
        XCTAssertFalse(wrongAccount)
        let refreshed = await model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertTrue(model.invitationNeedsRefresh)
        let stale = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 17, accountID: accountID
        )
        XCTAssertFalse(stale)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testAHouseholdSwitchDiscardsItsCachedOwnerAndCandidates() async throws {
        let (model, transport) = try await make([access(), fixture.state(householdID: fixture.otherHouseholdID)])
        _ = await model.loadHouseholdAccess()
        let switched = await model.select(id: fixture.otherHouseholdID)
        XCTAssertTrue(switched)
        XCTAssertNil(model.invitations)
        let stale = await model.transferOwnership(
            to: successorID, householdID: fixture.householdID, version: 17, accountID: accountID
        )
        XCTAssertFalse(stale)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/owner") == true })
    }

    func testMembersAndAdminsCannotOfferOwnerActions() async throws {
        for role in ["member", "admin"] {
            let (model, transport) = try await make([access(role: role)])
            _ = await model.loadHouseholdAccess()
            XCTAssertEqual(model.state?.memberships.first?.role.rawValue, role)
            XCTAssertTrue(model.invitations?.ownershipCandidates.isEmpty == true)
            let transferred = await model.transferOwnership(
                to: successorID, householdID: fixture.householdID, version: 17, accountID: accountID
            )
            XCTAssertFalse(transferred)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testMissingOrUnlinkedTargetsCannotBeSelectedForOwnership() async throws {
        var fields = accessFields()
        var roster = try XCTUnwrap(fields["members"] as? [[String: Any]])
        roster[1]["linked"] = false
        fields["members"] = roster
        let (model, transport) = try await make([response(fields)])
        _ = await model.loadHouseholdAccess()
        XCTAssertTrue(model.invitations?.ownershipCandidates.isEmpty == true)
        for memberID in [successorID, UUID()] {
            let transferred = await model.transferOwnership(
                to: memberID, householdID: fixture.householdID, version: 17, accountID: accountID
            )
            XCTAssertFalse(transferred)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testTheMembersSectionFitsNarrowAndAccessibleSheets() async throws {
        let (model, _) = try await make([access()])
        _ = await model.loadHouseholdAccess()
        for width in [CGFloat(320), 560, 834] {
            for type in [DynamicTypeSize.large, .accessibility5] {
                let controller = UIHostingController(rootView: AccountHouseholdMembersSection(model: model)
                    .environment(\.dynamicTypeSize, type).frame(width: width))
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 4000))
                XCTAssertEqual(size.width, width, accuracy: 0.5)
                XCTAssertGreaterThan(size.height, 44)
                XCTAssertLessThan(size.height, 4000)
            }
        }
    }

    private func household(version: Int = 17) -> [String: Any] {
        var result = fixture.household(id: fixture.householdID, version: version)
        result["members"] = [
            ["id": fixture.memberID, "name": "Ada", "color": "#81b29a"],
            ["id": successorID.uuidString, "name": "Sam", "color": "#7c89a1"]
        ]
        return result
    }

    private func state(version: Int = 17) throws -> HTTPResponse {
        try fixture.state(version: version, household: household(version: version))
    }

    private func accessFields(version: Int = 17, transferred: Bool = false, role: String? = nil) -> [String: Any] {
        let role = role ?? (transferred ? "member" : "owner")
        return [
            "household": household(version: version), "memberId": fixture.memberID, "role": role,
            "members": [
                ["memberId": fixture.memberID, "name": "Ada", "role": role, "linked": true, "active": true],
                ["memberId": successorID.uuidString, "name": "Sam",
                 "role": role == "owner" ? "member" : "owner", "linked": true, "active": true]
            ],
            "invitations": role == "owner" ? [fixture.invitation()] : []
        ]
    }

    private func access(version: Int = 17, transferred: Bool = false, role: String? = nil) throws -> HTTPResponse {
        try response(accessFields(version: version, transferred: transferred, role: role))
    }

    private func response(_ fields: [String: Any], status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(data: try JSONSerialization.data(withJSONObject: fields), statusCode: status, url: fixture.api.origin)
    }

    private func make(_ responses: [HTTPResponse], invitationOrigin: APIConfiguration? = nil) async throws
        -> (AccountModel, InvitationModelTransport) {
        let transport = InvitationModelTransport(responses: try [state()] + responses, holdIndex: nil)
        let client = AccountSession(configuration: fixture.api,
                                    tokenStore: InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43))),
                                    transport: transport)
        let model = AccountModel(client: client, invitationOrigin: invitationOrigin)
        await model.start()
        return (model, transport)
    }
}
