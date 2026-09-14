import XCTest

final class AccountUITests: XCTestCase {
    private enum FlowError: Error { case missingElement(String) }
    struct Seed: Decodable {
        struct Home: Decodable { let id: String; let name: String }
        let homes: [Home]
        let invitation: String
        let recoveryCode: String
    }

    @MainActor
    private func fixtureOrigin() throws -> URL {
        let bundle = Bundle(for: AccountUITests.self)
        guard let value = bundle.object(forInfoDictionaryKey: "RoomlingsTestAPIOrigin") as? String,
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
            throw XCTSkip("Run Scripts/test-accounts.mjs. The isolated API origin is missing from \(bundle.bundleURL.lastPathComponent).")
        }
        return url
    }

    @MainActor
    private func fixture(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try fixtureOrigin().appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    @MainActor
    private func launchApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ROOMLINGS_API_ORIGIN"] = try fixtureOrigin().absoluteString
        app.launchEnvironment["ROOMLINGS_KEYCHAIN_SERVICE"] = "com.roomlings.account-test.\(UUID().uuidString)"
        app.launch()
        guard app.textFields["Email address"].waitForExistence(timeout: 15) else {
            throw FlowError.missingElement("Email address")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sheet = app.otherElements["account-sheet"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            XCTAssertLessThan(sheet.frame.width, app.frame.width)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Web-themed account sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return app
    }

    @MainActor
    private func fill(_ field: XCUIElement, _ value: String) throws {
        guard field.waitForExistence(timeout: 10) else { throw FlowError.missingElement(field.description) }
        field.tap()
        if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    @MainActor
    private func tap(_ button: XCUIElement, in app: XCUIApplication) throws {
        guard button.waitForExistence(timeout: 10) else { throw FlowError.missingElement(button.description) }
        if !button.isHittable { app.swipeUp() }
        button.tap()
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, email: String) throws {
        try fill(app.textFields["Email address"], email)
        try tap(app.buttons["Send sign-in code"], in: app)
        try fill(app.textFields["Email sign-in code"], "123456")
        try fill(app.textFields["Display name"], "Ada")
        try tap(app.buttons["Verify and sign in"], in: app)
        try waitForSignedIn(app)
    }

    @MainActor
    private func waitForSignedIn(_ app: XCUIApplication) throws {
        let signedIn = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Account"),
            object: app.buttons["account-entry"]
        )
        guard XCTWaiter.wait(for: [signedIn], timeout: 15) == .completed else {
            throw FlowError.missingElement("Signed-in account state")
        }
    }

    @MainActor
    private func openAccount(_ app: XCUIApplication) throws {
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["account-sheet"]
        )
        guard XCTWaiter.wait(for: [dismissed], timeout: 15) == .completed else {
            throw FlowError.missingElement("Dismissed account sheet")
        }
        try tap(app.buttons["account-entry"], in: app)
    }

    @MainActor
    func testSignInRestoresTheSavedRoomSwitchesHomesAndSignsOut() async throws {
        continueAfterFailure = false
        let email = "room-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/seed", body: ["email": email])
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: 15))
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: 30))
        XCTAssertFalse(room.switches["Put the kettle on"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["Email address"].exists)
        try openAccount(app)
        try tap(app.buttons["Open Willow House"], in: app)
        XCTAssertTrue(app.staticTexts["Willow House"].waitForExistence(timeout: 15))
        XCTAssertTrue(room.switches["Put the kettle on"].waitForExistence(timeout: 30))
        try openAccount(app)
        try tap(app.buttons["Sign out"], in: app)
        guard app.staticTexts["Sign out on this device?"].waitForExistence(timeout: 10),
              let confirmation = app.buttons.matching(identifier: "Sign out").allElementsBoundByIndex.first(where: \.isHittable) else {
            throw FlowError.missingElement("Sign-out confirmation")
        }
        confirmation.tap()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: 15))
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.staticTexts["Kitchen preview"].exists)
    }

    @MainActor
    func testNewAccountsCanCreateAndJoinWithoutLosingTheCurrentHome() async throws {
        continueAfterFailure = false
        let ownerEmail = "owner-\(UUID().uuidString.lowercased())@example.test"
        let seeded = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": ownerEmail]))
        let app = try launchApp()
        try signIn(app, email: "new-\(UUID().uuidString.lowercased())@example.test")
        try tap(app.buttons["Create a household"], in: app)
        try fill(app.textFields["Household name"], "Our new home")
        try tap(app.buttons["Create household"], in: app)
        XCTAssertTrue(app.staticTexts["Our new home"].waitForExistence(timeout: 15))
        try openAccount(app)
        try tap(app.buttons["Join a household"], in: app)
        try fill(app.textFields["Invitation link or code"],
             "http://localhost:5173/#account-invite=\(seeded.invitation)")
        try fill(app.textFields["Your name in this household"], "Ben")
        try tap(app.buttons["Join household"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: 15))
        try openAccount(app)
        XCTAssertTrue(app.buttons["Open Our new home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Cedar House"].exists)
    }

    @MainActor
    func testRecoveryWorksAndDeliveryFailuresKeepTheEnteredEmail() async throws {
        continueAfterFailure = false
        let email = "recover-\(UUID().uuidString.lowercased())@example.test"
        let seeded = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        _ = try await fixture("_fixture/delivery", body: ["fail": true])
        let app = try launchApp()
        try fill(app.textFields["Email address"], email)
        try tap(app.buttons["Send sign-in code"], in: app)
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Email address"].value as? String, email)
        try tap(app.buttons["Use a recovery code"], in: app)
        try fill(app.secureTextFields["Account recovery code"], seeded.recoveryCode)
        try tap(app.buttons["Recover my account"], in: app)
        try waitForSignedIn(app)
        try openAccount(app)
        XCTAssertFalse(app.secureTextFields["Account recovery code"].exists)
        XCTAssertTrue(app.buttons["Open Cedar House"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Willow House"].exists)
        _ = try await fixture("_fixture/delivery", body: ["fail": false])
    }
}
