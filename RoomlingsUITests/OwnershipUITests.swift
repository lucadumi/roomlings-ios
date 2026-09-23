import XCTest

extension AccountUITests {
    private struct OwnershipSeed: Decodable {
        let ownerId: String
        let peerId: String
        let browserId: String
        let formerId: String
    }

    private struct OwnershipState: Decodable {
        struct Member: Decodable { let memberId: String; let role: String; let active: Bool }
        struct Request: Decodable { let version: Int; let memberId: String; let method: String; let native: Bool; let browserHeaders: Bool }
        let version: Int
        let members: [Member]
        let requests: [Request]
        let ledgerDigest: String
        let balances: [String: Int]
        let originalAccountExists: Bool
    }

    @MainActor
    private func ownershipState(_ home: Seed.Home) async throws -> OwnershipState {
        try JSONDecoder().decode(OwnershipState.self, from: await fixture(
            "_fixture/ownership/state", body: ["householdId": home.id]
        ))
    }

    @MainActor
    private func launchOwnership(asPeer: Bool = false) async throws -> (XCUIApplication, String, Seed.Home, OwnershipSeed) {
        let email = "ownership-\(UUID().uuidString.lowercased())@example.test"
        let peerEmail = "next-owner-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let members = try JSONDecoder().decode(OwnershipSeed.self, from: await fixture(
            "_fixture/ownership/seed", body: ["email": email, "peerEmail": peerEmail, "householdId": home.id, "invitation": seed.invitation]
        ))
        let app = try launchApp()
        try signIn(app, email: asPeer ? peerEmail : email)
        if app.buttons["household-entry"].label != home.name {
            try openAccount(app)
            try tap(app.buttons["Open \(home.name)"], in: app)
            XCTAssertTrue(app.staticTexts[home.name].waitForExistence(timeout: Wait.control))
        }
        try openAccount(app)
        return (app, email, home, members)
    }

    @MainActor
    private func openMembers(_ app: XCUIApplication) throws {
        try tap(app.buttons["manage-household-members"], in: app)
        XCTAssertTrue(app.otherElements["household-members"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func offerOwnership(_ peerID: String, in app: XCUIApplication) throws {
        try tap(app.buttons["transfer-ownership-\(peerID)"], in: app)
        XCTAssertTrue(app.staticTexts["Transfer household ownership?"].waitForExistence(timeout: Wait.control))
        let warning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam will manage household membership")).firstMatch
        XCTAssertTrue(warning.exists)
    }

    @MainActor
    func testOwnershipTransferConfirmsTheNamedMemberAndPreservesTheLedger() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, _, home, members) = try await launchOwnership()
        try openMembers(app)
        let before = try await ownershipState(home)
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.ownerId)"].exists)
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.browserId)"].exists)
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.formerId)"].exists)
        XCTAssertTrue(app.staticTexts["Admin; account linked"].exists)
        try offerOwnership(members.peerId, in: app)
        if app.buttons["Cancel"].exists {
            try tap(app.buttons["Cancel"], in: app)
        } else {
            // Native popovers omit the cancel action and dismiss on an outside tap.
            app.otherElements["household-members"].staticTexts[home.name]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Transfer household ownership?"]
        )
        let dismissal = await XCTWaiter.fulfillment(of: [dismissed], timeout: Wait.control)
        XCTAssertEqual(dismissal, .completed)
        let cancelled = try await ownershipState(home)
        XCTAssertTrue(cancelled.requests.isEmpty)
        XCTAssertEqual(cancelled.version, before.version)
        try offerOwnership(members.peerId, in: app)
        try tap(app.buttons["Transfer ownership"], in: app)
        XCTAssertTrue(app.staticTexts["Ownership transferred. You are still a household member."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.peerId)"].exists)
        let after = try await ownershipState(home)
        XCTAssertEqual(after.version, before.version + 1)
        XCTAssertEqual(after.members.first { $0.memberId == members.ownerId }?.role, "member")
        XCTAssertEqual(after.members.first { $0.memberId == members.peerId }?.role, "owner")
        XCTAssertEqual(after.ledgerDigest, before.ledgerDigest)
        XCTAssertEqual(after.balances, before.balances)
        XCTAssertEqual(after.requests.count, 1)
        XCTAssertEqual(after.requests.first?.memberId, members.peerId)
        XCTAssertEqual(after.requests.first?.version, before.version)
        XCTAssertTrue(after.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.method == "POST" })
        attachHeaderScreenshot("Native ownership transfer completed")
        try tap(app.buttons["Back to account"], in: app)
        XCTAssertFalse(app.buttons["create-invitation"].exists)
        try tap(app.buttons["Done"], in: app)
        try openMoney(app)
        XCTAssertTrue(app.otherElements["money-sheet"].exists)
        try tap(app.buttons["Done"], in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["account-entry"].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        try openMembers(app)
        XCTAssertTrue(app.staticTexts["Only the current owner can transfer ownership."].exists)
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.peerId)"].exists)
    }

    @MainActor
    func testAnUnconfirmedOwnershipTransferMustBeRefreshedWithoutRepeatingIt() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, _, home, members) = try await launchOwnership()
        try openMembers(app)
        let before = try await ownershipState(home)
        _ = try await fixture("_fixture/ownership/failure", body: ["mode": "lost-response"])
        try offerOwnership(members.peerId, in: app)
        try tap(app.buttons["Transfer ownership"], in: app)
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.peerId)"].isEnabled)
        XCTAssertFalse(app.staticTexts["Ownership transferred. You are still a household member."].exists)
        let uncertain = try await ownershipState(home)
        XCTAssertEqual(uncertain.requests.count, 1)
        XCTAssertEqual(uncertain.version, before.version + 1)
        try tap(app.buttons["refresh-household-members"], in: app)
        XCTAssertTrue(app.staticTexts["Only the current owner can transfer ownership."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.peerId)"].exists)
        let refreshed = try await ownershipState(home)
        XCTAssertEqual(refreshed.requests.count, 1)
        XCTAssertEqual(refreshed.ledgerDigest, before.ledgerDigest)
    }

    @MainActor
    func testAStaleOwnershipConfirmationRequiresReviewBeforeANewHandoff() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, email, home, members) = try await launchOwnership()
        try tap(app.buttons["open-account-deletion"], in: app)
        try fill(app.textFields["Account email to confirm deletion"], email)
        try tap(app.buttons["confirm-account-deletion"], in: app)
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["manage-ownership-before-deletion"], in: app)
        try openMembers(app)
        let before = try await ownershipState(home)
        try offerOwnership(members.peerId, in: app)
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id])
        try tap(app.buttons["Transfer ownership"], in: app)
        XCTAssertTrue(app.staticTexts["The household changed elsewhere. Refresh household members and review ownership before continuing."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["transfer-ownership-\(members.peerId)"].isEnabled)
        let conflict = try await ownershipState(home)
        XCTAssertEqual(conflict.members.first { $0.memberId == members.ownerId }?.role, "owner")
        try tap(app.buttons["refresh-household-members"], in: app)
        try offerOwnership(members.peerId, in: app)
        try tap(app.buttons["Transfer ownership"], in: app)
        XCTAssertTrue(app.staticTexts["Ownership transferred. You are still a household member."].waitForExistence(timeout: Wait.control))
        let transferred = try await ownershipState(home)
        XCTAssertEqual(transferred.requests.map(\.version), [before.version, conflict.version])
        XCTAssertEqual(transferred.ledgerDigest, before.ledgerDigest)
        try tap(app.buttons["Back to account"], in: app)
        try tap(app.buttons["open-account-deletion"], in: app)
        try fill(app.textFields["Account email to confirm deletion"], email)
        try tap(app.buttons["confirm-account-deletion"], in: app)
        XCTAssertTrue(app.staticTexts["Account deleted. Shared ledger history kept."].waitForExistence(timeout: Wait.control))
        let deleted = try await ownershipState(home)
        XCTAssertFalse(deleted.originalAccountExists)
        XCTAssertEqual(deleted.members.first { $0.memberId == members.peerId }?.role, "owner")
        XCTAssertEqual(deleted.ledgerDigest, before.ledgerDigest)
        XCTAssertEqual(deleted.balances, before.balances)
    }

    @MainActor
    func testHouseholdAdminsCanReadMembersButCannotTransferOwnership() async throws {
        continueAfterFailure = false
        let (app, _, home, _) = try await launchOwnership(asPeer: true)
        try openMembers(app)
        XCTAssertTrue(app.staticTexts["Only the current owner can transfer ownership."].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transfer-ownership-")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Member; browser access only"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Former roommate")).firstMatch.exists)
        let state = try await ownershipState(home)
        XCTAssertTrue(state.requests.isEmpty)
    }
}
