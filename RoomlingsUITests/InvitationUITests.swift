import XCTest

extension AccountUITests {
    private struct InvitationState: Decodable {
        struct Invitation: Decodable {
            let id: String
            let uses: Int
            let revokedAt: String?
            let code: String?
        }
        struct Request: Decodable {
            let path: String
            let method: String
            let version: Int
            let native: Bool
            let browserHeaders: Bool
        }
        let version: Int
        let invitations: [Invitation]
        let requests: [Request]
    }

    @MainActor
    private func invitationState(email: String, home: Seed.Home) async throws -> InvitationState {
        try JSONDecoder().decode(InvitationState.self, from: await fixture(
            "_fixture/invitations/state", body: ["email": email, "householdId": home.id]
        ))
    }

    @MainActor
    private func launchInvitations() async throws -> (XCUIApplication, String, Seed.Home) {
        let email = "invitations-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        XCTAssertTrue(app.buttons["create-invitation"].waitForExistence(timeout: Wait.control))
        return (app, email, home)
    }

    @MainActor
    private func revokeInvitation(_ id: String, in app: XCUIApplication) throws {
        try tap(app.buttons["Revoke invitation \(id)"], in: app)
        XCTAssertTrue(app.staticTexts["Revoke this invitation?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Revoke invitation"], in: app)
    }

    @MainActor
    func testInvitationsShareJoinAndRejectARevokedLink() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (owner, email, home) = try await launchInvitations()
        let before = try await invitationState(email: email, home: home)
        try tap(owner.buttons["create-invitation"], in: owner)
        XCTAssertTrue(owner.buttons["share-invitation"].waitForExistence(timeout: Wait.control))
        let created = try await invitationState(email: email, home: home)
        XCTAssertEqual(created.version, before.version + 1)
        let invitation = try XCTUnwrap(created.invitations.first { candidate in
            !before.invitations.contains { $0.id == candidate.id }
        })
        let code = try XCTUnwrap(invitation.code)
        let link = "\(Self.invitationWebOrigin)/#account-invite=\(code)"
        XCTAssertEqual(invitation.uses, 0)
        XCTAssertTrue(created.requests.allSatisfy { $0.native && !$0.browserHeaders })
        owner.buttons["share-invitation"].tap()
        let copy = owner.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: Wait.control), "The native share sheet must offer its Copy action.")
        // The system share extension has its own coordinate space, unlike the app's scroll views.
        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: Wait.control), .completed)
        try tap(owner.buttons["Done"], in: owner)
        owner.terminate()

        let member = try launchApp()
        try signIn(member, email: "invited-\(UUID().uuidString.lowercased())@example.test")
        try tap(member.buttons["Join a household"], in: member)
        let invitationField = member.textFields["Invitation link or code"]
        try tap(invitationField, in: member)
        invitationField.press(forDuration: 1)
        let paste = member.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: Wait.control))
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            invitationField.value as? String == link
        }, object: invitationField)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: Wait.control), .completed,
                       "The system Copy action must paste only the complete invitation URL, including its fragment.")
        let unaccepted = try await invitationState(email: email, home: home)
        XCTAssertEqual(unaccepted.invitations.first { $0.id == invitation.id }?.uses, 0)
        try fill(member.textFields["Your name in this household"], "Ada")
        try tap(member.buttons["Join household"], in: member)
        XCTAssertTrue(member.staticTexts[
            "That name may already be taken, or a household or account limit was reached. Try another name or ask the owner to check."
        ].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(member.textFields["Invitation link or code"].value as? String, link)
        XCTAssertEqual(member.textFields["Your name in this household"].value as? String, "Ada")
        let conflicted = try await invitationState(email: email, home: home)
        XCTAssertEqual(conflicted.invitations.first { $0.id == invitation.id }?.uses, 0)
        try fill(member.textFields["Your name in this household"], "Sam")
        try tap(member.buttons["Join household"], in: member)
        XCTAssertTrue(member.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(member.buttons["account-entry"].value as? String, "Playing as Sam")
        attachHeaderScreenshot("Native saved invited-member header, portrait")
        try openAccount(member)
        XCTAssertTrue(member.staticTexts["Only the household owner can create or revoke invitations. Ask them to share a link."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertFalse(member.buttons["create-invitation"].exists)
        member.terminate()

        owner.launch()
        XCTAssertTrue(owner.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openAccount(owner)
        XCTAssertFalse(owner.buttons["share-invitation"].exists)
        try revokeInvitation(invitation.id, in: owner)
        XCTAssertTrue(owner.staticTexts["Invitation revoked. People who already joined keep their membership."]
            .waitForExistence(timeout: Wait.control))
        let revoked = try await invitationState(email: email, home: home)
        XCTAssertNotNil(revoked.invitations.first { $0.id == invitation.id }?.revokedAt)
        XCTAssertEqual(revoked.invitations.first { $0.id == invitation.id }?.uses, 1)
        owner.terminate()

        let late = try launchApp(invitationLink: link)
        try signIn(late, email: "late-\(UUID().uuidString.lowercased())@example.test")
        try fill(late.textFields["Your name in this household"], "Ben")
        try tap(late.buttons["Join household"], in: late)
        XCTAssertTrue(late.staticTexts["That invitation is invalid, expired or revoked. Ask the owner for a new link."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertTrue(late.textFields["Invitation link or code"].exists)
        XCTAssertEqual(late.textFields["Your name in this household"].value as? String, "Ben")
        XCTAssertEqual(late.buttons["household-entry"].label, "Kitchen preview")
    }

    @MainActor
    func testInvitationsRequireRefreshAfterALostResponseAndAConflict() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, email, home) = try await launchInvitations()
        let before = try await invitationState(email: email, home: home)
        _ = try await fixture("_fixture/invitations/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["create-invitation"], in: app)
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["create-invitation"].isEnabled)
        XCTAssertFalse(app.buttons["share-invitation"].exists)
        let uncertain = try await invitationState(email: email, home: home)
        XCTAssertEqual(uncertain.invitations.count, before.invitations.count + 1)
        XCTAssertEqual(uncertain.requests.filter { $0.method == "POST" }.count, 1)
        let invitation = try XCTUnwrap(uncertain.invitations.first { candidate in
            !before.invitations.contains { $0.id == candidate.id }
        })
        XCTAssertNil(invitation.code)
        try tap(app.buttons["refresh-invitations"], in: app)
        let refreshed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["create-invitation"]
        )
        guard await XCTWaiter.fulfillment(of: [refreshed], timeout: Wait.control) == .completed else {
            let error = app.staticTexts["account-error"]
            XCTFail("Invitation refresh did not finish. Account error: \(error.exists ? error.label : "none").")
            return
        }
        XCTAssertFalse(app.buttons["share-invitation"].exists)
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id])
        try revokeInvitation(invitation.id, in: app)
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["create-invitation"].isEnabled)
        let conflicted = try await invitationState(email: email, home: home)
        XCTAssertNil(conflicted.invitations.first { $0.id == invitation.id }?.revokedAt)
        try tap(app.buttons["refresh-invitations"], in: app)
        try revokeInvitation(invitation.id, in: app)
        XCTAssertTrue(app.staticTexts["Invitation revoked. People who already joined keep their membership."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["invitation-\(invitation.id)"].exists)
        let final = try await invitationState(email: email, home: home)
        XCTAssertEqual(final.requests.map(\.method), ["POST", "DELETE", "DELETE"])
        XCTAssertTrue(final.requests.allSatisfy { $0.native && !$0.browserHeaders })
    }

    @MainActor
    func testWebFirstJoiningRestoresNativelyAndReopeningTheLinkDoesNotDuplicateMembership() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let ownerEmail = "web-owner-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": ownerEmail]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let email = "web-invite-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/invitations/browser-accept", body: ["email": email, "invitation": seed.invitation])
        let app = try launchApp()
        try signIn(app, email: email)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        struct BrowserState: Decodable { let signedIn: Bool; let householdId: String }
        let browser = try JSONDecoder().decode(BrowserState.self, from: await fixture(
            "_fixture/invitations/browser-state", body: ["email": email]
        ))
        XCTAssertTrue(browser.signedIn)
        XCTAssertEqual(browser.householdId, home.id)
        let before = try await invitationState(email: ownerEmail, home: home)
        XCTAssertEqual(before.invitations.first?.uses, 1)
        app.terminate()
        app.launchEnvironment["ROOMLINGS_INVITATION_URL"] = "\(Self.invitationWebOrigin)/#account-invite=\(seed.invitation)"
        app.launch()
        XCTAssertTrue(app.textFields["Invitation link or code"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Invitation link or code"].value as? String, seed.invitation)
        XCTAssertFalse(app.textFields["Email address"].exists)
        try tap(app.buttons["Join household"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        let after = try await invitationState(email: ownerEmail, home: home)
        XCTAssertEqual(after.invitations.first?.uses, 1)
        XCTAssertEqual(after.version, before.version)
    }
}
