import XCTest

extension AccountUITests {
    private struct MembershipSeed: Decodable {
        let ownerId: String
        let peerId: String?
        let browserId: String?
        let formerId: String?
        let subjectId: String
        let otherHome: Seed.Home?
    }

    private struct MembershipState: Decodable {
        struct Member: Decodable {
            let id: String
            let name: String
            let inactive: Bool
            let browserAccess: Bool
            let recoveryAccess: Bool
        }
        struct Item: Decodable { let createdBy: String; let claimedBy: String?; let pickedUp: Bool; let version: Int }
        struct Request: Decodable { let path: String; let method: String; let version: Int; let native: Bool; let browserHeaders: Bool }
        let version: Int
        let ownerId: String?
        let members: [Member]
        let items: [Item]
        let accountAlive: Bool
        let subjectMemberships: [String]
        let requests: [Request]
        let ledgerDigest: String
        let balances: [String: Int]
    }

    @MainActor
    private func membershipState(_ home: Seed.Home) async throws -> MembershipState {
        try JSONDecoder().decode(MembershipState.self, from: await fixture(
            "_fixture/membership/state", body: ["householdId": home.id]
        ))
    }

    @MainActor
    private func launchMembership(asOwner: Bool = false, withPeers: Bool = true) async throws
        -> (XCUIApplication, Seed.Home, MembershipSeed) {
        let email = "membership-owner-\(UUID().uuidString.lowercased())@example.test"
        let peerEmail = "membership-peer-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let members = try JSONDecoder().decode(MembershipSeed.self, from: await fixture(
            "_fixture/membership/seed",
            body: ["email": email, "peerEmail": peerEmail, "householdId": home.id, "invitation": seed.invitation, "withPeers": withPeers]
        ))
        let app = try launchApp()
        try signIn(app, email: asOwner || !withPeers ? email : peerEmail)
        if app.buttons["household-entry"].label != home.name {
            try openAccount(app)
            try tap(app.buttons["Open \(home.name)"], in: app)
            XCTAssertTrue(app.staticTexts[home.name].waitForExistence(timeout: Wait.control))
        }
        try openAccount(app)
        try tap(app.buttons["manage-household-members"], in: app)
        XCTAssertTrue(app.otherElements["household-members"].waitForExistence(timeout: Wait.control))
        return (app, home, members)
    }

    @MainActor
    private func offerDeparture(_ app: XCUIApplication) throws {
        try tap(app.buttons["leave-household"], in: app)
        XCTAssertTrue(app.staticTexts["Leave this household?"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func offerRemoval(_ id: String, in app: XCUIApplication) throws {
        try tap(app.buttons["remove-member-\(id)"], in: app)
        XCTAssertTrue(app.staticTexts["Remove this roommate's access?"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func cancelMembershipDialog(_ title: String, in app: XCUIApplication) async throws {
        if app.buttons["Cancel"].exists {
            try tap(app.buttons["Cancel"], in: app)
        } else {
            // The header can be a popover passthrough view. Tap the body gutter instead.
            let body = app.otherElements["account-sheet"].scrollViews.firstMatch
            XCTAssertTrue(body.exists)
            body.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 8, dy: 24)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts[title])
        let result = await XCTWaiter.fulfillment(of: [dismissed], timeout: Wait.control)
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    private func assertRetainedHistory(_ before: MembershipState, _ after: MembershipState, subject: String) throws {
        XCTAssertEqual(after.ledgerDigest, before.ledgerDigest)
        XCTAssertEqual(after.balances, before.balances)
        XCTAssertTrue(after.accountAlive)
        let member = try XCTUnwrap(after.members.first { $0.id == subject })
        XCTAssertTrue(member.inactive)
        XCTAssertFalse(member.browserAccess)
        XCTAssertFalse(member.recoveryAccess)
        let items = after.items.filter { $0.createdBy == subject }
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.claimedBy == nil && !$0.pickedUp && $0.version == 1 })
    }

    @MainActor
    func testLeavingAHouseholdPreservesOtherHomesAndRevokesItsOldAccess() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home, seed) = try await launchMembership()
        let before = try await membershipState(home)
        let other = try XCTUnwrap(seed.otherHome)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-member-")).firstMatch.exists)
        let original = try XCTUnwrap(before.members.first { $0.id == seed.subjectId })
        XCTAssertTrue(original.browserAccess)
        XCTAssertTrue(original.recoveryAccess)
        try offerDeparture(app)
        try await cancelMembershipDialog("Leave this household?", in: app)
        let cancelled = try await membershipState(home)
        XCTAssertTrue(cancelled.requests.isEmpty)
        try offerDeparture(app)
        try tap(app.buttons["Leave household"], in: app)
        XCTAssertTrue(app.staticTexts["You left the household. Shared debts and history remain."].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["account-entry"].label, "Account")
        XCTAssertEqual(app.buttons["household-entry"].label, "Kitchen preview")
        XCTAssertFalse(app.buttons["Open \(home.name)"].exists)
        XCTAssertTrue(app.buttons["Open \(other.name)"].exists)
        let after = try await membershipState(home)
        try assertRetainedHistory(before, after, subject: seed.subjectId)
        XCTAssertEqual(after.requests.count, 1)
        XCTAssertEqual(after.requests.first?.version, before.version)
        XCTAssertTrue(after.requests.allSatisfy { $0.method == "DELETE" && $0.native && !$0.browserHeaders })
        XCTAssertEqual(after.subjectMemberships, [other.id])
        struct InvitationResult: Decodable { let accepted: Bool }
        let invitation = try JSONDecoder().decode(InvitationResult.self, from: await fixture(
            "_fixture/membership/old-invitation", body: ["householdId": home.id]
        ))
        XCTAssertFalse(invitation.accepted)
        try tap(app.buttons["Open \(other.name)"], in: app)
        XCTAssertTrue(app.staticTexts[other.name].waitForExistence(timeout: Wait.control))
        try openMoney(app)
        try tap(app.buttons["Done"], in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[other.name].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        XCTAssertFalse(app.buttons["Open \(home.name)"].exists)
    }

    @MainActor
    func testOwnersRemoveAccountAndBrowserAccessWithoutDeletingSharedHistory() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home, seed) = try await launchMembership(asOwner: true)
        let peer = try XCTUnwrap(seed.peerId)
        let browser = try XCTUnwrap(seed.browserId)
        let former = try XCTUnwrap(seed.formerId)
        let before = try await membershipState(home)
        XCTAssertFalse(app.buttons["leave-household"].isEnabled)
        XCTAssertFalse(app.buttons["remove-member-\(seed.ownerId)"].exists)
        XCTAssertFalse(app.buttons["remove-member-\(former)"].exists)
        try offerRemoval(peer, in: app)
        try await cancelMembershipDialog("Remove this roommate's access?", in: app)
        let cancelled = try await membershipState(home)
        XCTAssertTrue(cancelled.requests.isEmpty)
        try offerRemoval(peer, in: app)
        try tap(app.buttons["Remove access"], in: app)
        XCTAssertTrue(app.staticTexts["Roommate access removed. Shared debts and history kept."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["remove-member-\(peer)"].exists)
        let afterPeer = try await membershipState(home)
        try assertRetainedHistory(before, afterPeer, subject: peer)
        XCTAssertEqual(afterPeer.ownerId, seed.ownerId)
        XCTAssertTrue(afterPeer.members.first { $0.id == browser }?.browserAccess == true)
        try offerRemoval(browser, in: app)
        try tap(app.buttons["Remove access"], in: app)
        let browserRemoved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                       object: app.buttons["remove-member-\(browser)"])
        let finished = await XCTWaiter.fulfillment(of: [browserRemoved], timeout: Wait.control)
        XCTAssertEqual(finished, .completed)
        let afterBrowser = try await membershipState(home)
        try assertRetainedHistory(before, afterBrowser, subject: browser)
        XCTAssertEqual(afterBrowser.requests.count, 2)
        XCTAssertTrue(app.buttons["leave-household"].isEnabled)
        attachHeaderScreenshot("Native member access removal retains former roommates")
    }

    @MainActor
    func testStaleAndUnconfirmedRemovalsRequireRefreshingMembers() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home, seed) = try await launchMembership(asOwner: true)
        let peer = try XCTUnwrap(seed.peerId)
        let before = try await membershipState(home)
        try offerRemoval(peer, in: app)
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id])
        try tap(app.buttons["Remove access"], in: app)
        let error = app.staticTexts["account-error"]
        XCTAssertTrue(error.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["remove-member-\(peer)"].isEnabled)
        let rejected = try await membershipState(home)
        XCTAssertFalse(try XCTUnwrap(rejected.members.first { $0.id == peer }).inactive)
        try tap(app.buttons["refresh-household-members"], in: app)
        _ = try await fixture("_fixture/membership/failure", body: ["mode": "lost-response"])
        try offerRemoval(peer, in: app)
        try tap(app.buttons["Remove access"], in: app)
        XCTAssertTrue(error.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Roommate access removed. Shared debts and history kept."].exists)
        let uncertain = try await membershipState(home)
        XCTAssertTrue(try XCTUnwrap(uncertain.members.first { $0.id == peer }).inactive)
        try tap(app.buttons["refresh-household-members"], in: app)
        XCTAssertTrue(app.buttons["leave-household"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["remove-member-\(peer)"].exists)
        let refreshed = try await membershipState(home)
        XCTAssertEqual(refreshed.requests.count, uncertain.requests.count)
        XCTAssertEqual(refreshed.ledgerDigest, before.ledgerDigest)
    }

    @MainActor
    func testAnUnconfirmedLeaveBlocksHouseholdActionsUntilAccountRefresh() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home, seed) = try await launchMembership()
        let other = try XCTUnwrap(seed.otherHome)
        _ = try await fixture("_fixture/membership/failure", body: ["mode": "lost-response"])
        try offerDeparture(app)
        try tap(app.buttons["Leave household"], in: app)
        XCTAssertTrue(app.buttons["refresh-membership-access"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["You left the household. Shared debts and history remain."].exists)
        XCTAssertFalse(app.buttons["Open \(other.name)"].exists)
        XCTAssertEqual(app.buttons["household-entry"].label, "Kitchen preview")
        let uncertain = try await membershipState(home)
        XCTAssertFalse(uncertain.subjectMemberships.contains(home.id))
        try tap(app.buttons["refresh-membership-access"], in: app)
        XCTAssertTrue(app.staticTexts["You no longer have access to that household. Shared debts and history remain."].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.buttons["Open \(other.name)"].exists)
        XCTAssertFalse(app.buttons["Open \(home.name)"].exists)
        let refreshed = try await membershipState(home)
        XCTAssertEqual(refreshed.requests.count, uncertain.requests.count)
        XCTAssertTrue(refreshed.accountAlive)
    }

    @MainActor
    func testASoleOwnerCanLeaveAndCloseAccessWithoutDeletingTheirAccount() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home, seed) = try await launchMembership(asOwner: true, withPeers: false)
        let before = try await membershipState(home)
        XCTAssertTrue(app.buttons["leave-household"].isEnabled)
        try offerDeparture(app)
        try tap(app.buttons["Leave household"], in: app)
        XCTAssertTrue(app.staticTexts["You left the household. Shared debts and history remain."].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["account-entry"].label, "Account")
        XCTAssertTrue(app.buttons["Open Willow House"].exists)
        let after = try await membershipState(home)
        try assertRetainedHistory(before, after, subject: seed.subjectId)
        XCTAssertNil(after.ownerId)
        XCTAssertEqual(after.requests.count, 1)
    }
}
