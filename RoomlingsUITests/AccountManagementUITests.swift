import XCTest

extension AccountUITests {
    private struct ManagedAccount: Decodable {
        let name: String
        let sessions: [String]
        let recoveryCodes: Int
    }

    @MainActor
    private func managedAccount(_ email: String) async throws -> ManagedAccount {
        try JSONDecoder().decode(ManagedAccount.self, from: await fixture("_fixture/account/state", body: ["email": email]))
    }

    @MainActor
    private func backToAccount(_ app: XCUIApplication) throws {
        try tap(app.buttons["Back to account"], in: app)
        XCTAssertTrue(app.buttons["open-profile"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func confirm(_ title: String, in app: XCUIApplication) throws {
        let button = app.buttons.matching(identifier: title).allElementsBoundByIndex.first(where: \.isHittable)
            ?? app.sheets.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: Wait.control), "\(title) confirmation")
        button.tap()
    }

    @MainActor
    func testAccountProfileSessionsAndRecoveryCodesMatchTheServer() async throws {
        continueAfterFailure = false
        let email = "manage-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/seed", body: ["email": email])
        let app = try launchApp()
        try signIn(app, email: email)
        _ = try await fixture("_fixture/account/other-session", body: ["email": email])
        try openAccount(app)

        // Profile
        try tap(app.buttons["open-profile"], in: app)
        try fill(app.textFields["Your account name"], "Ada Lovelace")
        try tap(app.buttons["save-account-name"], in: app)
        XCTAssertTrue(app.staticTexts["Account name saved. Ledger names unchanged."].waitForExistence(timeout: Wait.control))
        try fill(app.textFields["This device's name"], "Kitchen iPhone")
        try tap(app.buttons["save-device-name"], in: app)
        XCTAssertTrue(app.staticTexts["Device name saved."].waitForExistence(timeout: Wait.control))
        var saved = try await managedAccount(email)
        XCTAssertEqual(saved.name, "Ada Lovelace")
        XCTAssertTrue(saved.sessions.contains("Kitchen iPhone"))
        try backToAccount(app)

        // Sessions: only the other device can be revoked here.
        try tap(app.buttons["open-devices"], in: app)
        let revoke = app.buttons["Revoke Old laptop"]
        XCTAssertTrue(revoke.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Revoke Kitchen iPhone"].exists)
        try tap(revoke, in: app)
        try confirm("Revoke session", in: app)
        XCTAssertTrue(app.staticTexts["Account session revoked."].waitForExistence(timeout: Wait.control))
        saved = try await managedAccount(email)
        XCTAssertEqual(saved.sessions, ["Kitchen iPhone"])
        try backToAccount(app)

        // Recovery codes need a recent sign-in before they change.
        XCTAssertEqual(saved.recoveryCodes, 10)
        _ = try await fixture("_fixture/deletion/age-session", body: ["email": email])
        try tap(app.buttons["open-recovery-codes"], in: app)
        XCTAssertTrue(app.staticTexts["10 unused recovery codes"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["generate-recovery-codes"], in: app)
        try confirm("Replace recovery codes", in: app)
        XCTAssertTrue(app.staticTexts["Verify your email again before changing recovery codes."].waitForExistence(timeout: Wait.control))
        let unchanged = try await managedAccount(email)
        XCTAssertEqual(unchanged.recoveryCodes, 10)
        try tap(app.buttons["verify-for-recovery"], in: app)
        try tap(app.buttons["send-deletion-verification"], in: app)
        try fill(app.textFields["Email sign-in code"], "123456")
        try tap(app.buttons["verify-deletion-email"], in: app,
                until: app.staticTexts["Email verified. You can now change your recovery codes."])

        try tap(app.buttons["generate-recovery-codes"], in: app)
        try confirm("Replace recovery codes", in: app)
        let list = app.otherElements["recovery-code-list"]
        XCTAssertTrue(list.waitForExistence(timeout: Wait.control))
        let codes = list.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(codes.count, 10)
        XCTAssertTrue(codes.allSatisfy { $0.hasPrefix("roomlings-account-") })
        try tap(app.buttons["copy-recovery-codes"], in: app)
        XCTAssertTrue(app.buttons["Recovery codes copied"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["saved-recovery-codes"], in: app)
        XCTAssertTrue(app.staticTexts["Recovery codes ready. Keep your copy private."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["recovery-code-list"].exists, "Codes must not be shown again.")

        try tap(app.buttons["revoke-recovery-codes"], in: app)
        try confirm("Revoke recovery codes", in: app)
        XCTAssertTrue(app.staticTexts["0 unused recovery codes"].waitForExistence(timeout: Wait.control))
        let revoked = try await managedAccount(email)
        XCTAssertEqual(revoked.recoveryCodes, 0)
    }
}
