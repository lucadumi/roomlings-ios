import Foundation
import RoomlingsCore
import SwiftUI
import UIKit
import XCTest
@testable import Roomlings

@MainActor
final class InvitationModelTests: XCTestCase {
    func testAnIncomingInvitationSurvivesRestoreAndSignInUntilExplicitAcceptance() async throws {
        let (model, transport, _) = try makeModel([
            fixture.state(signedIn: false), fixture.state(token: true), fixture.state()
        ])
        model.receiveInvitation(try fixture.link())
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        let initialRequests = await transport.requests
        XCTAssertTrue(initialRequests.isEmpty)
        await model.start()
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        let signedIn = await model.verify(email: "ada@example.test", code: "123456", name: "Ada", label: "iPhone")
        XCTAssertTrue(signedIn)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        let beforeJoin = await transport.requests
        XCTAssertEqual(beforeJoin.map { $0.url?.path }, ["/api/account", "/api/account/verify"])
        let joined = await model.join(code: fixture.code, memberName: "Ada")
        XCTAssertTrue(joined)
        XCTAssertNil(model.pendingInvitation)
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.url?.path, "/api/account/invitations/accept")
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.roomlings.example" && $0.url?.fragment == nil })
    }

    func testConfirmedExpiryPreservesTheInvitationForRecovery() async throws {
        let (model, _, _) = try makeModel([
            fixture.state(), fixture.failure(401, code: "ACCOUNT_SESSION_REQUIRED"), fixture.state(token: true)
        ])
        await model.start()
        model.receiveInvitation(try fixture.link())
        let joined = await model.join(code: fixture.code, memberName: "Ada")
        XCTAssertFalse(joined)
        XCTAssertFalse(model.signedIn)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        let recovered = await model.recover(
            email: "ada@example.test", code: "roomlings-account-abcd-1234-abcd-1234-abcd-1234-abcd-1234", label: "iPhone"
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
    }

    func testARevokedInvitationKeepsTheExistingHouseholdAndShowsAReadableError() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.failure(410)])
        await model.start()
        let previous = model.state
        model.receiveInvitation(try fixture.link())
        let joined = await model.join(code: fixture.code, memberName: "Ada")
        XCTAssertFalse(joined)
        XCTAssertEqual(model.state, previous)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        XCTAssertEqual(model.message, "That invitation is invalid, expired or revoked. Ask the owner for a new link.")
        XCTAssertNil(model.notice)
    }

    func testAJoinConflictPreservesTheInvitationAndExplainsHowToContinue() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.failure(409)])
        await model.start()
        let previous = model.state
        model.receiveInvitation(try fixture.link())
        let joined = await model.join(code: fixture.code, memberName: "Ada")
        XCTAssertFalse(joined)
        XCTAssertEqual(model.state, previous)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        XCTAssertEqual(model.message,
                       "That name may already be taken, or a household or account limit was reached. Try another name or ask the owner to check.")
        XCTAssertNil(model.notice)
    }

    func testFailedCredentialStorageDoesNotConsumeTheInvitationOrClaimSignIn() async throws {
        let (model, _, store) = try makeModel([fixture.state(signedIn: false), fixture.state(token: true)])
        await model.start()
        await store.failSaves()
        model.receiveInvitation(try fixture.link())
        let signedIn = await model.verify(email: "ada@example.test", code: "123456", name: "Ada", label: "iPhone")
        XCTAssertFalse(signedIn)
        XCTAssertFalse(model.signedIn)
        XCTAssertEqual(model.pendingInvitation?.value, fixture.code)
        XCTAssertEqual(model.message, "Saved access could not be updated securely. Unlock the device and try again.")
    }

    func testANewerIncomingInvitationIsNotConsumedByAnEarlierJoin() async throws {
        let (model, transport, _) = try makeModel([fixture.state(), fixture.state()], holdIndex: 1)
        await model.start()
        model.receiveInvitation(try fixture.link())
        let join = Task { await model.join(code: fixture.code, memberName: "Ada") }
        await transport.started.wait()
        let next = "roomlings-invite-" + String(repeating: "B", count: 43)
        model.receiveInvitation(try fixture.link(code: next))
        await transport.finish.signal()
        let joined = await join.value
        XCTAssertTrue(joined)
        XCTAssertEqual(model.pendingInvitation?.value, next)
    }

    func testInvalidAndUnconfiguredLinksAreRejectedWithoutRequestsOrURLDisclosure() async throws {
        let (model, transport, store) = try makeModel([])
        model.receiveInvitation(try fixture.link())
        let untrusted = try XCTUnwrap(URL(string: "https://other.example/#account-invite=\(fixture.code)"))
        model.receiveInvitation(untrusted)
        XCTAssertNil(model.pendingInvitation)
        XCTAssertNotNil(model.incomingInvitationError)
        XCTAssertFalse(model.incomingInvitationError?.contains(fixture.code) == true)
        let unconfigured = AccountModel(client: AccountSession(
            configuration: fixture.api, tokenStore: store, transport: transport
        ))
        unconfigured.receiveInvitation(try fixture.link())
        XCTAssertNotNil(unconfigured.incomingInvitationError)
        XCTAssertNil(unconfigured.pendingInvitation)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testChangingHouseholdsDiscardsTheOneTimeShareLink() async throws {
        let (model, _, _) = try makeModel([
            fixture.state(), fixture.created(), fixture.state(householdID: fixture.otherHouseholdID)
        ])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        XCTAssertEqual(model.invitationLink, try fixture.link())
        let selected = await model.select(id: fixture.otherHouseholdID)
        XCTAssertTrue(selected)
        XCTAssertNil(model.invitationLink)
        XCTAssertNil(model.invitations)
    }

    func testIncomingAccountAndRecoveryURLsCannotBeTreatedAsInvitations() async throws {
        let (model, transport, _) = try makeModel([])
        for suffix in [
            "/recover#account-invite=\(fixture.code)",
            "/?code=private#account-invite=\(fixture.code)",
            "/#account-invite=\(fixture.code)&recovery=private"
        ] {
            model.receiveInvitation(try XCTUnwrap(URL(string: "\(fixture.origin.origin)\(suffix)")))
            XCTAssertNil(model.pendingInvitation)
            let error = try XCTUnwrap(model.incomingInvitationError)
            XCTAssertFalse(error.contains(fixture.code))
            XCTAssertFalse(error.contains("private"))
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAnUncertainCreationRequiresRefreshInsteadOfOfferingAnotherSave() async throws {
        let (model, transport, _) = try makeModel([fixture.state(), fixture.failure(503), fixture.access()])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertFalse(created)
        XCTAssertTrue(model.invitationNeedsRefresh)
        XCTAssertNil(model.invitationLink)
        XCTAssertNil(model.notice)
        let repeated = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertFalse(repeated)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let refreshed = await model.loadInvitations()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(model.invitationNeedsRefresh)
        XCTAssertNil(model.invitationLink)
        XCTAssertEqual(model.invitations?.invitations.count, 1)
    }

    func testRevokingTheSharedInvitationRemovesItsShareAction() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.created(), fixture.access(version: 19, revoked: true)])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        XCTAssertTrue(model.canShareInvitation(at: fixture.now))
        let revoked = await model.revokeInvitation(id: fixture.invitationID, householdID: fixture.householdID, version: 18)
        XCTAssertTrue(revoked)
        XCTAssertNil(model.invitationLink)
        XCTAssertFalse(model.canShareInvitation(at: fixture.now))
        XCTAssertEqual(model.notice, "Invitation revoked. People who already joined keep their membership.")
    }

    func testLosingOwnerAccessDiscardsInvitationHistoryAndTheShareLink() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.created(), fixture.access(version: 19, owner: false)])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        let refreshed = await model.loadInvitations()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.invitations?.role, .member)
        XCTAssertEqual(model.invitations?.invitations.count, 0)
        XCTAssertNil(model.invitationLink)
    }

    func testAnUnconfiguredLinkOriginStillAllowsAccountAccessAndRevocation() async throws {
        let (model, transport, _) = try makeModel([
            fixture.state(), fixture.access(), fixture.access(version: 19, revoked: true)
        ], configureInvitations: false)
        await model.start()
        XCTAssertTrue(model.canUseAccount)
        let loaded = await model.loadInvitations()
        XCTAssertTrue(loaded)
        let created = await model.createInvitation(householdID: fixture.householdID, version: 18)
        XCTAssertFalse(created)
        XCTAssertNotNil(model.invitationSetupError)
        XCTAssertEqual(model.message, model.invitationSetupError)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.invitationLink)
        XCTAssertFalse(model.invitationNeedsRefresh)
        let revoked = await model.revokeInvitation(id: fixture.invitationID, householdID: fixture.householdID, version: 18)
        XCTAssertTrue(revoked)
        XCTAssertTrue(model.canUseAccount)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "DELETE"])
    }

    func testClosingAccountDiscardsTheOneTimeShareLink() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.created()])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        XCTAssertTrue(model.canShareInvitation(at: fixture.now))
        model.clearInvitationLink()
        XCTAssertNil(model.invitationLink)
        XCTAssertFalse(model.canShareInvitation(at: fixture.now))
        XCTAssertEqual(model.invitations?.invitations.count, 1)
    }

    func testAnInvitationCannotBeSharedAtOrAfterItsExpiry() async throws {
        let (model, _, _) = try makeModel([fixture.state(), fixture.created()])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        let expiry = try XCTUnwrap(model.invitations?.invitations.first?.expiresAt)
        XCTAssertTrue(model.canShareInvitation(at: expiry.addingTimeInterval(-0.001)))
        XCTAssertFalse(model.canShareInvitation(at: expiry))
        XCTAssertFalse(model.canShareInvitation(at: expiry.addingTimeInterval(1)))
    }

    func testHouseholdRefreshRequiresCurrentInvitationsBeforeSharing() async throws {
        let (model, _, _) = try makeModel([
            fixture.state(), fixture.created(), fixture.state(version: 19), fixture.access(version: 19, revoked: true)
        ])
        await model.start()
        let created = await model.createInvitation(householdID: fixture.householdID, version: 17)
        XCTAssertTrue(created)
        XCTAssertTrue(model.canShareInvitation(at: fixture.now))
        let refreshed = await model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertTrue(model.invitationNeedsRefresh)
        XCTAssertFalse(model.canShareInvitation(at: fixture.now))
        let loaded = await model.loadInvitations()
        XCTAssertTrue(loaded)
        XCTAssertFalse(model.invitationNeedsRefresh)
        XCTAssertNil(model.invitationLink)
        XCTAssertFalse(model.canShareInvitation(at: fixture.now))
    }

    private let fixture = InvitationModelFixture()

    private func makeModel(_ responses: [HTTPResponse], holdIndex: Int? = nil, configureInvitations: Bool = true) throws
        -> (AccountModel, InvitationModelTransport, InvitationModelStore) {
        let transport = InvitationModelTransport(responses: responses, holdIndex: holdIndex)
        let store = InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let client = AccountSession(configuration: fixture.api, tokenStore: store, transport: transport)
        return (AccountModel(client: client, invitationOrigin: configureInvitations ? fixture.origin : nil), transport, store)
    }
}

@MainActor
final class AccountHeaderTests: XCTestCase {
    func testTheAvatarUsesThePersistedMemberAndUpdatesWithTheHousehold() async throws {
        let initial = household(memberName: "Élodie", color: "#C9533A")
        let changed = household(memberName: "Bea", color: "#7c89a1")
        let (model, _) = try makeModel([fixture.state(household: initial), fixture.state(household: changed)])
        await model.start()
        XCTAssertEqual(model.state?.account?.name, "Ada")
        XCTAssertEqual(model.viewer?.name, "Élodie")
        XCTAssertEqual(model.viewerColor?.rgb, 0xc9533a)
        XCTAssertNil(model.viewerFailure)
        let message = try model.room.message(paused: false)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        for privateValue in ["Élodie", "#C9533A", fixture.memberID, "ada@example.test", "private-test-invitation"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        let refreshed = await model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.viewer?.name, "Bea")
        XCTAssertEqual(model.viewerColor?.rgb, 0x7c89a1)
    }

    func testFailedRequestsCannotLookLoadedAfterTheirMessageIsDismissed() async throws {
        let (model, transport) = try makeModel(
            [fixture.state(), fixture.failure(503), fixture.state()], holdIndex: 1
        )
        XCTAssertEqual(model.headerStatus, .preview)
        await model.start()
        XCTAssertEqual(model.headerStatus, .loaded)
        let previous = model.viewer
        let refresh = Task { await model.refresh() }
        await transport.started.wait()
        XCTAssertEqual(model.headerStatus, .updating)
        await transport.finish.signal()
        let failed = await refresh.value
        XCTAssertFalse(failed)
        XCTAssertEqual(model.viewer, previous)
        XCTAssertEqual(model.headerStatus, .needsAttention)
        XCTAssertNotNil(model.message)
        model.clearFeedback()
        XCTAssertNil(model.message)
        XCTAssertEqual(model.headerStatus, .needsAttention)
        let recovered = await model.refresh()
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.headerStatus, .loaded)
    }

    func testUnsupportedAvatarColoursKeepTheAccountAndExposeAVisibleReason() async throws {
        let (model, _) = try makeModel([fixture.state(household: household(memberName: "Ada", color: "red"))])
        await model.start()
        XCTAssertTrue(model.canUseAccount)
        XCTAssertEqual(model.viewer?.color, "red")
        XCTAssertNil(model.viewerColor)
        XCTAssertEqual(model.viewerFailure, "Your saved member colour could not be displayed. Refresh your account.")
        XCTAssertEqual(model.headerStatus, .needsAttention)
        model.clearFeedback()
        XCTAssertNotNil(model.viewerFailure)
        XCTAssertEqual(model.room.householdID, fixture.householdID.uuidString.lowercased())
    }

    func testRosterProjectionFailuresDoNotMasqueradeAsMissingMembership() async throws {
        var snapshot = household(memberName: "Ada", color: "#81b29a")
        snapshot["members"] = (0..<13).map { index in
            ["id": index == 0 ? fixture.memberID : UUID().uuidString, "name": "Roommate \(index)", "color": "#81b29a"]
        }
        let (model, _) = try makeModel([fixture.state(household: snapshot)])
        await model.start()
        XCTAssertTrue(model.canUseAccount)
        XCTAssertNotNil(model.state?.session)
        XCTAssertNil(model.viewer)
        XCTAssertEqual(model.viewerFailure, "Your household member could not be displayed. Refresh your account.")
        XCTAssertEqual(model.headerStatus, .needsAttention)
    }

    func testUnselectedSignedOutAndDeletingAccountsDoNotRetainAnAvatar() async throws {
        let states = try [
            fixture.state(selectedHousehold: false),
            fixture.state(signedIn: false),
            fixture.state(selectedHousehold: false, deletionPending: true)
        ]
        for state in states {
            let (model, _) = try makeModel([fixture.state(), state])
            await model.start()
            XCTAssertNotNil(model.viewer)
            let refreshed = await model.refresh()
            XCTAssertTrue(refreshed)
            XCTAssertNil(model.viewer)
            XCTAssertNil(model.viewerColor)
            XCTAssertNil(model.viewerFailure)
            XCTAssertNil(model.householdName)
            XCTAssertEqual(model.headerStatus, model.deletionPending ? .needsAttention : .preview)
        }
    }

    func testHeaderOnlyAddsRowsWhenItsMeasuredContentsNeedThem() async throws {
        var snapshot = household(memberName: "Élodie", color: "#81b29a")
        snapshot["name"] = "The little household at the end of Maple Avenue"
        let (model, _) = try makeModel([fixture.state(household: snapshot)])
        await model.start()
        let narrow = headerSize(model: model, width: 320)
        let wide = headerSize(model: model, width: 1024)
        XCTAssertEqual(narrow.width, 320, accuracy: 0.5)
        XCTAssertEqual(wide.width, 1024, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(narrow.height, 126)
        XCTAssertLessThanOrEqual(wide.height, 80)
        for width in [CGFloat(320), 402, 550, 834, 874] {
            let accessible = headerSize(model: model, width: width, dynamicType: .accessibility5)
            XCTAssertEqual(accessible.width, width, accuracy: 0.5)
            XCTAssertGreaterThan(accessible.height, wide.height)
            XCTAssertLessThan(accessible.height, 1000)
        }
    }

    func testTheSignedOutPillAlsoFitsANarrowAccessibilityLayout() throws {
        let (model, _) = try makeModel([])
        let standard = headerSize(model: model, width: 402)
        let accessible = headerSize(model: model, width: 320, dynamicType: .accessibility5)
        XCTAssertLessThanOrEqual(standard.height, 80)
        XCTAssertEqual(accessible.width, 320, accuracy: 0.5)
        XCTAssertGreaterThan(accessible.height, standard.height)
    }

    func testTheApprovedMarkKeepsItsSizeAtLargeType() {
        let controller = UIHostingController(rootView: RoomBrandMark(size: 36)
            .environment(\.dynamicTypeSize, .accessibility5))
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: 500))
        XCTAssertEqual(size.width, 36)
        XCTAssertEqual(size.height, 36)
    }

    func testSavedMemberColoursResolveToTheirExactOpaqueNativeRGB() throws {
        for (hex, expected) in [("#C9533A", UInt32(0xc9533a)), ("#7c89a1", 0x7c89a1), ("#000000", 0)] {
            let color = try XCTUnwrap(HouseholdMemberColor(hex: hex))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            XCTAssertTrue(UIColor(RoomTheme.member(color)).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, CGFloat(expected >> 16 & 255) / 255, accuracy: 0.000_001)
            XCTAssertEqual(green, CGFloat(expected >> 8 & 255) / 255, accuracy: 0.000_001)
            XCTAssertEqual(blue, CGFloat(expected & 255) / 255, accuracy: 0.000_001)
            XCTAssertEqual(alpha, 1)
        }
    }

    private let fixture = InvitationModelFixture()

    private func household(memberName: String, color: String) -> [String: Any] {
        var household = fixture.household(id: fixture.householdID, version: 17)
        household["members"] = [["id": fixture.memberID, "name": memberName, "color": color]]
        return household
    }

    private func makeModel(_ responses: [HTTPResponse], holdIndex: Int? = nil) throws
        -> (AccountModel, InvitationModelTransport) {
        let transport = InvitationModelTransport(responses: responses, holdIndex: holdIndex)
        let store = InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let client = AccountSession(configuration: fixture.api, tokenStore: store, transport: transport)
        return (AccountModel(client: client), transport)
    }

    private func headerSize(model: AccountModel, width: CGFloat, dynamicType: DynamicTypeSize = .large) -> CGSize {
        let controller = UIHostingController(rootView: RoomAccountHeader(accounts: model, openAccount: {})
            .environment(\.dynamicTypeSize, dynamicType)
            .frame(width: width))
        return controller.sizeThatFits(in: CGSize(width: width, height: 2000))
    }
}

struct InvitationModelFixture {
    let api = try! APIConfiguration(origin: "https://api.roomlings.example")
    let origin = try! APIConfiguration(origin: "https://roomlings.example")
    let code = "roomlings-invite-Ab_-0123" + String(repeating: "Z", count: 35)
    let householdID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let otherHouseholdID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let memberID = "22222222-2222-4222-8222-222222222222"
    let invitationID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    let now = Date()

    func link(code: String? = nil) throws -> URL {
        try AccountInvitationCode(code ?? self.code).link(origin: origin)
    }

    func household(id: UUID, version: Int) -> [String: Any] {
        [
            "id": id.uuidString, "name": "Our home", "currency": "EUR", "budget": 25_000, "version": version,
            "inviteCode": "private-test-invitation", "roomStyle": "clay",
            "members": [["id": memberID, "name": "Ada", "color": "#81b29a"]],
            "expenses": [], "settlements": [], "roomComponents": []
        ]
    }

    func state(signedIn: Bool = true, token: Bool = false, householdID: UUID? = nil, version: Int = 17,
               household: [String: Any]? = nil, selectedHousehold: Bool = true, deletionPending: Bool = false) throws -> HTTPResponse {
        let id = householdID ?? self.householdID
        let timestamp = now.ISO8601Format()
        let selected = signedIn && selectedHousehold && !deletionPending
        var fields: [String: Any] = [
            "configured": true,
            "account": signedIn ? [
                "id": "33333333-3333-4333-8333-333333333333", "email": "ada@example.test",
                "name": "Ada", "createdAt": timestamp
            ] : NSNull(),
            "devices": signedIn ? [[
                "id": "44444444-4444-4444-8444-444444444444", "label": "iPhone", "current": true,
                "createdAt": timestamp, "lastUsedAt": timestamp, "expiresAt": now.addingTimeInterval(86_400).ISO8601Format()
            ]] : [],
            "memberships": selected ? [[
                "householdId": id.uuidString, "householdName": "Our home", "memberId": memberID,
                "currency": "EUR", "role": "owner"
            ]] : [],
            "csrfToken": signedIn ? String(repeating: "c", count: 64) : NSNull(),
            "session": selected ? [
                "token": NSNull(), "memberId": memberID, "household": household ?? self.household(id: id, version: version)
            ] : NSNull()
        ]
        if token { fields["accessToken"] = String(repeating: "b", count: 43) }
        if deletionPending { fields["deletionPending"] = true }
        return try response(fields)
    }

    func invitation(revoked: Bool = false) -> [String: Any] {
        [
            "id": invitationID.uuidString, "createdAt": now.ISO8601Format(),
            "expiresAt": now.addingTimeInterval(7 * 86_400).ISO8601Format(),
            "revokedAt": revoked ? now.ISO8601Format() : NSNull(), "uses": 0
        ]
    }

    func accessFields(version: Int = 18, revoked: Bool = false, owner: Bool = true) -> [String: Any] {
        [
            "household": household(id: householdID, version: version), "memberId": memberID,
            "members": [["memberId": memberID, "name": "Ada", "role": owner ? "owner" : "member", "linked": true, "active": true]],
            "role": owner ? "owner" : "member", "invitations": owner ? [invitation(revoked: revoked)] : []
        ]
    }

    func access(version: Int = 18, revoked: Bool = false, owner: Bool = true) throws -> HTTPResponse {
        try response(accessFields(version: version, revoked: revoked, owner: owner))
    }

    func created() throws -> HTTPResponse {
        try response(["code": code, "invitation": invitation(), "access": accessFields()], status: 201)
    }

    func failure(_ status: Int, code: String? = nil) throws -> HTTPResponse {
        var fields = ["error": "Test request failed"]
        if let code { fields["code"] = code }
        return try response(fields, status: status)
    }

    private func response(_ fields: [String: Any], status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(data: try JSONSerialization.data(withJSONObject: fields), statusCode: status, url: api.origin)
    }
}

actor InvitationModelStore: SessionTokenStore {
    private var token: SessionToken?
    private var saveFails = false

    init(token: SessionToken?) { self.token = token }
    func read() -> SessionToken? { token }
    func save(_ token: SessionToken) throws {
        if saveFails { throw AccountError.credentialStorage }
        self.token = token
    }
    func clear() { token = nil }
    func failSaves() { saveFails = true }
}

actor InvitationModelSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if !signalled { await withCheckedContinuation { waiter = $0 } }
    }
    func signal() {
        signalled = true
        waiter?.resume()
        waiter = nil
    }
}

actor InvitationModelTransport: HTTPTransport {
    let started = InvitationModelSignal()
    let finish = InvitationModelSignal()
    private(set) var requests: [URLRequest] = []
    private let responses: [HTTPResponse]
    private let holdIndex: Int?

    init(responses: [HTTPResponse], holdIndex: Int?) {
        self.responses = responses
        self.holdIndex = holdIndex
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let index = requests.count
        requests.append(request)
        guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
        if index == holdIndex {
            await started.signal()
            await finish.wait()
        }
        return responses[index]
    }
}
