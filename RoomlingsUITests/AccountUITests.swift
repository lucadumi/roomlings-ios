import XCTest

final class AccountUITests: XCTestCase {
    static let invitationWebOrigin = "https://roomlings.example.test"
    private enum FlowError: Error { case missingElement(String) }
    struct Seed: Decodable {
        struct Home: Decodable { let id: String; let name: String }
        let homes: [Home]
        let invitation: String
        let recoveryCode: String
    }

    private struct ChoreState: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String
            let dueDate: String?
            let repeatDays: Int?
            let occurrence: Int
            let componentId: String?
            let componentName: String?
        }
        struct Completion: Decodable {
            let id: String
            let choreId: String
            let title: String
            let undoneAt: String?
        }
        struct Request: Decodable {
            let path: String
            let version: Int
            let mutationId: String?
            let mutationVersion: Int?
            let native: Bool
            let browserHeaders: Bool
        }
        let version: Int
        let items: [Item]
        let history: [Completion]
        let requests: [Request]
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
    func fixture(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try fixtureOrigin().appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    @MainActor
    func launchApp(systemControls: Bool = false, invitationLink: String? = nil,
                   notificationPayload: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = systemControls ? ["-roomlings-system-controls"] : []
        app.launchEnvironment["ROOMLINGS_API_ORIGIN"] = try fixtureOrigin().absoluteString
        app.launchEnvironment["ROOMLINGS_INVITATION_ORIGIN"] = Self.invitationWebOrigin
        app.launchEnvironment["ROOMLINGS_INVITATION_URL"] = invitationLink
        app.launchEnvironment["ROOMLINGS_NOTIFICATION_PAYLOAD"] = notificationPayload
        app.launchEnvironment["ROOMLINGS_KEYCHAIN_SERVICE"] = "com.roomlings.account-test.\(UUID().uuidString)"
        app.launch()
        guard app.textFields["Email address"].waitForExistence(timeout: Wait.control) else {
            throw FlowError.missingElement("Email address")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sheet = app.otherElements["account-sheet"]
            XCTAssertTrue(sheet.waitForExistence(timeout: Wait.control))
            XCTAssertLessThan(sheet.frame.width, app.frame.width)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Web-themed account sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return app
    }

    @MainActor
    func fill(_ field: XCUIElement, _ value: String) throws {
        guard field.waitForExistence(timeout: Wait.control) else { throw FlowError.missingElement(field.description) }
        // A loaded simulator drops synthesized keystrokes while SwiftUI rebuilds the form, so
        // confirm what actually landed rather than trusting a single typeText.
        for _ in 1...3 {
            try tap(field, in: XCUIApplication())
            if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            field.typeText(value)
            // Secure fields report bullets instead of the text, so there is nothing to compare.
            if field.elementType == .secureTextField { return }
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
            if XCTWaiter.wait(for: [landed], timeout: Wait.flip) == .completed { return }
        }
        throw FlowError.missingElement("\(field.description) kept \(field.value as? String ?? "nothing") instead of \(value)")
    }

    @MainActor
    func tap(_ button: XCUIElement, in app: XCUIApplication) throws {
        guard button.exists || button.waitForExistence(timeout: Wait.control) else {
            throw FlowError.missingElement(button.description)
        }
        if !button.isEnabled {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
            guard XCTWaiter.wait(for: [enabled], timeout: Wait.control) == .completed else {
                throw FlowError.missingElement("\(button.description) stayed disabled")
            }
        }
        let identifier = button.identifier
        let name = identifier.isEmpty ? button.label : identifier
        let scroll = app.scrollViews.containing(button.elementType, identifier: name).firstMatch
        for attempt in 0...8 {
            let appFrame = app.frame
            let frame = button.frame
            let canScroll = scroll.exists
            var area = canScroll ? scroll.frame.intersection(appFrame) : appFrame
            let keyboard = app.keyboards.firstMatch
            if canScroll && keyboard.exists {
                let keyboardFrame = keyboard.frame
                if keyboardFrame.minY > area.minY + 44 && keyboardFrame.intersects(area) {
                    // The whole control must clear the keyboard. Extra space makes the last
                    // visible row unreachable when the form is already at its scroll limit.
                    area.size.height = min(area.height, keyboardFrame.minY - area.minY)
                }
            }
            // Asking XCTest for offscreen hit points can fail before scrolling ever starts.
            if !frame.isEmpty && area.contains(frame) {
                if !button.isHittable {
                    let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: button)
                    guard XCTWaiter.wait(for: [reachable], timeout: Wait.flip) == .completed else {
                        throw FlowError.missingElement("\(button.description) is visible but blocked")
                    }
                }
                button.tap()
                return
            }
            guard canScroll, attempt < 8 else { throw FlowError.missingElement("\(button.description) could not be reached") }
            guard area.height > 44 else { throw FlowError.missingElement("A visible scroll area for \(button.description)") }
            let down = frame.minY < area.minY
            let gap = down ? area.minY - frame.minY : frame.maxY - area.maxY
            // Leave a control-height margin so a revealed button clears the home indicator.
            let distance = min(max(44, gap + 44), area.height * 0.6)
            // Use the sheet's gutter so dragging cannot focus a text field or open a menu.
            let x = area.minX - appFrame.minX + 8
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let middle = area.midY - appFrame.minY
            let start = origin.withOffset(CGVector(dx: x, dy: middle + (down ? -distance : distance) / 2))
            let end = origin.withOffset(CGVector(dx: x, dy: middle + (down ? distance : -distance) / 2))
            // Settle before lifting so a short fitted sheet cannot fling past the target in both directions.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    @MainActor
    func selectSegment(_ option: String, from identifier: String, in app: XCUIApplication) throws {
        let button = app.segmentedControls[identifier].buttons[option]
        guard button.exists || button.waitForExistence(timeout: Wait.control) else {
            throw FlowError.missingElement("\(option) segment in \(identifier)")
        }
        // Selecting the same segment is idempotent; never infer selection from a tap alone.
        for _ in 0..<3 {
            if button.isSelected { return }
            try tap(button, in: app)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
            if XCTWaiter.wait(for: [selected], timeout: Wait.flip) == .completed { return }
        }
        throw FlowError.missingElement("\(option) segment in \(identifier) did not become selected")
    }

    @MainActor
    func switchIsOn(_ control: XCUIElement) throws -> Bool {
        switch control.value as? String {
        case "1", "On": true
        case "0", "Off": false
        default: throw FlowError.missingElement("\(control.description) has no valid switch state")
        }
    }

    @MainActor
    func setSwitch(_ control: XCUIElement, on: Bool, in app: XCUIApplication) throws {
        guard control.exists || control.waitForExistence(timeout: Wait.control) else {
            throw FlowError.missingElement(control.description)
        }
        let wanted = on ? ["1", "On"] : ["0", "Off"]
        for _ in 0..<3 {
            if try switchIsOn(control) == on { return }
            try tap(control, in: app)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value IN %@", wanted), object: control)
            if XCTWaiter.wait(for: [changed], timeout: Wait.flip) == .completed { return }
        }
        throw FlowError.missingElement("\(control.description) did not change to \(wanted)")
    }

    @MainActor
    func signIn(_ app: XCUIApplication, email: String) throws {
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
        guard XCTWaiter.wait(for: [signedIn], timeout: Wait.control) == .completed else {
            throw FlowError.missingElement("Signed-in account state")
        }
    }

    // Signing in only settles the account. The household loads after it, so sampling the
    // status here races that load instead of waiting for the state under test.
    @MainActor
    private func expectHeaderStatus(_ app: XCUIApplication, _ status: String) {
        let entry = app.buttons["household-entry"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", status), object: entry)
        if XCTWaiter.wait(for: [matched], timeout: Wait.control) != .completed {
            XCTFail("The header status stayed \(entry.value as? String ?? "unset") instead of reaching \(status).")
        }
    }

    @MainActor
    func openAccount(_ app: XCUIApplication) throws {
        let sheet = app.otherElements["account-sheet"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        guard XCTWaiter.wait(for: [dismissed], timeout: Wait.control) == .completed else {
            throw FlowError.missingElement("Dismissed account sheet")
        }
        // The room can swallow the first tap while it settles after a household change. The
        // sheet still being closed proves it never opened, and the entry only ever opens it,
        // so tapping again cannot toggle it back shut.
        for _ in 1...3 {
            try tap(app.buttons["account-entry"], in: app)
            if sheet.waitForExistence(timeout: Wait.flip) { return }
        }
        throw FlowError.missingElement("Opened account sheet")
    }

    @MainActor
    func testAccountHeaderUsesTheSavedMemberAndKeepsLongHouseholdNamesReadable() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        _ = try await fixture("_fixture/seed", body: ["email": "header-owner-\(UUID().uuidString.lowercased())@example.test"])
        let app = try launchApp()
        try signIn(app, email: "header-\(UUID().uuidString.lowercased())@example.test")
        XCTAssertEqual(app.buttons["account-entry"].label, "Account")
        XCTAssertTrue((app.buttons["account-entry"].value as? String ?? "").isEmpty)
        try tap(app.buttons["Done"], in: app)
        try openAccount(app)
        try tap(app.buttons["Create a household"], in: app)
        let name = "The little household at the end of Maple Avenue"
        try fill(app.textFields["Household name"], name)
        try fill(app.textFields["Your name in this household"], "Bea")
        try tap(app.buttons["Create household"], in: app)
        let title = app.buttons["household-entry"]
        let titleUpdated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", name), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [titleUpdated], timeout: Wait.control), .completed)
        let account = app.buttons["account-entry"]
        XCTAssertEqual(account.label, "Account")
        XCTAssertEqual(account.value as? String, "Playing as Bea")
        let household = app.buttons["household-entry"]
        for button in [account, household] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.frame.contains(button.frame))
            XCTAssertTrue(button.isHittable)
        }
        XCTAssertFalse(account.frame.intersects(household.frame))
        attachHeaderScreenshot("Native saved-member header, portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: Wait.control), .completed)
        for button in [account, household] {
            XCTAssertTrue(app.frame.contains(button.frame))
            XCTAssertTrue(button.isHittable)
        }
        attachHeaderScreenshot("Native saved-member header, landscape")
        try tap(household, in: app)
        XCTAssertTrue(app.otherElements["account-sheet"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        try tap(app.buttons["Done"], in: app)
        XCTAssertEqual(app.buttons["household-entry"].label, name)
        try openAccount(app)
        XCTAssertTrue(app.buttons["Open \(name)"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    func testTheHeaderDoesNotClaimHouseholdLoadedAfterARequestFails() async throws {
        continueAfterFailure = false
        let email = "header-status-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/seed", body: ["email": email])
        let app = try launchApp()
        try signIn(app, email: email)
        expectHeaderStatus(app, "Household loaded")
        _ = try await fixture("_fixture/loading", body: ["hold": true, "fail": true])
        addTeardownBlock { @MainActor in
            _ = try await self.fixture("_fixture/loading", body: ["hold": false])
        }
        try openAccount(app)
        let loader = app.descendants(matching: .any).matching(identifier: "sheet-loading").firstMatch
        XCTAssertTrue(loader.waitForExistence(timeout: Wait.control))
        _ = try await fixture("_fixture/loading", body: ["hold": false])
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        attachHeaderScreenshot("Native account error matches shared web feedback")
        try tap(app.buttons["Done"], in: app)
        XCTAssertEqual(app.buttons["household-entry"].value as? String, "Account needs attention")
        attachHeaderScreenshot("Native account status after a failed request")
        try openAccount(app)
        XCTAssertTrue(app.buttons["Open Cedar House"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Done"], in: app)
        expectHeaderStatus(app, "Household loaded")
    }

    @MainActor
    func attachHeaderScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        XCTAssertFalse(room.switches["Put the kettle on"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.textFields["Email address"].exists)
        try openAccount(app)
        try tap(app.buttons["Open Willow House"], in: app)
        XCTAssertTrue(app.staticTexts["Willow House"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(room.switches["Put the kettle on"].waitForExistence(timeout: Wait.room))
        try openAccount(app)
        try tap(app.buttons["Sign out"], in: app)
        guard app.staticTexts["Sign out on this device?"].waitForExistence(timeout: Wait.control),
              let confirmation = app.buttons.matching(identifier: "Sign out").allElementsBoundByIndex.first(where: \.isHittable) else {
            throw FlowError.missingElement("Sign-out confirmation")
        }
        confirmation.tap()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: Wait.control))
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
        try choose("USD", from: "Currency", in: app)
        XCTAssertEqual(picker("Currency", in: app).value as? String, "USD")
        try tap(app.buttons["Create household"], in: app)
        XCTAssertTrue(app.staticTexts["Our new home"].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        try tap(app.buttons["Join a household"], in: app)
        try fill(app.textFields["Invitation link or code"],
             "http://localhost:5173/#account-invite=\(seeded.invitation)")
        try fill(app.textFields["Your name in this household"], "Ben")
        try tap(app.buttons["Join household"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        XCTAssertTrue(app.buttons["Open Our new home"].waitForExistence(timeout: Wait.control))
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
        XCTAssertTrue(app.staticTexts["account-error"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Email address"].value as? String, email)
        try tap(app.buttons["Use a recovery code"], in: app)
        try fill(app.secureTextFields["Account recovery code"], seeded.recoveryCode)
        try tap(app.buttons["Recover my account"], in: app)
        try waitForSignedIn(app)
        try openAccount(app)
        XCTAssertFalse(app.secureTextFields["Account recovery code"].exists)
        XCTAssertTrue(app.buttons["Open Cedar House"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.buttons["Open Willow House"].exists)
        _ = try await fixture("_fixture/delivery", body: ["fail": false])
    }

    @MainActor
    func openChores(_ app: XCUIApplication, objectName: String? = nil) throws {
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        let sheet = app.otherElements["chores-sheet"]
        let label = objectName.map { "Chores for \($0)" } ?? "Chores"
        let control = room.descendants(matching: .any).matching(identifier: label).firstMatch
        guard control.waitForExistence(timeout: Wait.control) else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Room chores accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            throw FlowError.missingElement("Chores room control")
        }
        for _ in 1...3 {
            try tap(control, in: app)
            if sheet.waitForExistence(timeout: Wait.flip) {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    XCTAssertLessThan(sheet.frame.width, app.frame.width)
                }
                return
            }
        }
        throw FlowError.missingElement("Opened chores sheet")
    }

    @MainActor
    private func launchChores(systemControls: Bool = false) async throws -> (XCUIApplication, Seed.Home) {
        let email = "chores-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp(systemControls: systemControls)
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openChores(app)
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        return (app, home)
    }

    @MainActor
    private func choreState(_ householdID: String) async throws -> ChoreState {
        try JSONDecoder().decode(ChoreState.self, from: await fixture("_fixture/chores/state", body: ["householdId": householdID]))
    }

    @MainActor
    private func picker(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", label)).firstMatch
    }

    @MainActor
    private func choose(_ option: String, from label: String, in app: XCUIApplication) throws {
        try tap(picker(label, in: app), in: app)
        try tap(app.buttons[option], in: app)
    }

    @MainActor
    private func exerciseChoreControls(_ app: XCUIApplication, screenshotName: String) throws {
        try choose("Whole home", from: "Chore room", in: app)
        XCTAssertTrue(app.staticTexts["No chores here yet."].waitForExistence(timeout: Wait.control))
        try choose("Kitchen", from: "Chore room", in: app)
        let mine = app.switches["My turn only"]
        try tap(mine, in: app)
        XCTAssertTrue(try switchIsOn(mine))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try tap(mine, in: app)
        XCTAssertFalse(try switchIsOn(mine))
        try selectSegment("Archived", from: "chore-sections", in: app)
        XCTAssertTrue(app.staticTexts["No archived chores."].waitForExistence(timeout: Wait.control))
        try selectSegment("Chores", from: "chore-sections", in: app)
    }

    @MainActor
    func testChoreControlsCanReturnToSystemStyling() throws {
        try exerciseControlFixture(systemControls: true)
    }

    @MainActor
    func testStyledControlsKeepBindingsAndDisabledStates() throws {
        try exerciseControlFixture(systemControls: false)
    }

    @MainActor
    private func exerciseControlFixture(systemControls: Bool) throws {
        executionTimeAllowance = 120
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-roomlings-control-fixture",
            systemControls ? "-roomlings-system-controls" : "-roomlings-custom-controls",
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["control-fixture"].waitForExistence(timeout: Wait.control))
        let value = app.staticTexts["fixture-selection"]
        XCTAssertEqual(value.label, "Kitchen|off|Chores")
        try choose("Bathroom", from: "Room", in: app)
        XCTAssertEqual(value.label, "Bathroom|off|Chores")
        let offScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        offScreenshot.name = systemControls ? "Original switch off" : "Themed switch off"
        offScreenshot.lifetime = .keepAlways
        add(offScreenshot)
        let mine = app.switches["My turn only"]
        XCTAssertTrue(mine.waitForExistence(timeout: Wait.control))
        let nativeSwitch = mine.switches.firstMatch.exists ? mine.switches.firstMatch : mine
        XCTAssertTrue(nativeSwitch.isHittable, nativeSwitch.debugDescription)
        if !systemControls { XCTAssertEqual(app.switches.count, 2) }
        try tap(nativeSwitch, in: app)
        XCTAssertEqual(value.label, "Bathroom|on|Chores")
        let onScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        onScreenshot.name = systemControls ? "Original switch on" : "Themed switch on"
        onScreenshot.lifetime = .keepAlways
        add(onScreenshot)
        try tap(nativeSwitch, in: app)
        XCTAssertEqual(value.label, "Bathroom|off|Chores")
        if !systemControls {
            let edge = nativeSwitch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            let off = edge.withOffset(CGVector(dx: -39, dy: 0))
            let on = edge.withOffset(CGVector(dx: -13, dy: 0))
            off.press(forDuration: 0.05, thenDragTo: on)
            XCTAssertEqual(value.label, "Bathroom|on|Chores")
            on.press(forDuration: 0.05, thenDragTo: off)
            XCTAssertEqual(value.label, "Bathroom|off|Chores")
        }
        let segments = app.segmentedControls["fixture-segments"]
        try selectSegment("History", from: "fixture-segments", in: app)
        XCTAssertEqual(value.label, "Bathroom|off|History")
        let enable = app.switches["Enable controls"]
        let nativeEnable = enable.switches.firstMatch.exists ? enable.switches.firstMatch : enable
        try tap(nativeEnable, in: app)
        XCTAssertFalse(try switchIsOn(enable))
        XCTAssertFalse(picker("Room", in: app).isEnabled)
        XCTAssertFalse(mine.isEnabled)
        XCTAssertFalse(segments.buttons["Archived"].isEnabled)
        XCTAssertEqual(value.label, "Bathroom|off|History")
        try tap(nativeEnable, in: app)
        try choose("Kitchen", from: "Room", in: app)
        XCTAssertEqual(value.label, "Kitchen|off|History")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = systemControls ? "Original control fixture" : "Styled control fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testChoresCreateAndCompleteInTheSharedHousehold() async throws {
        // Signing in, styling the controls, creating a chore, completing it, undoing it and
        // relaunching is the longest flow here, and an iPad runner takes about half again as
        // long as an iPhone one. This budget only catches a hang, it is not a speed target.
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        try exerciseChoreControls(app, screenshotName: "Roomlings control styling trial")
        let initial = try await choreState(home.id)
        let paused = try XCTUnwrap(initial.items.first { $0.title == "Clean the stored kettle" })
        XCTAssertFalse(app.otherElements["chore-\(paused.id)"].buttons["Mark done"].isEnabled)
        let objectChore = try XCTUnwrap(initial.items.first { $0.title == "Wipe the fridge shelves" })
        let objectName = try XCTUnwrap(objectChore.componentName)
        try tap(app.buttons["Done"], in: app)
        try openChores(app, objectName: objectName)
        XCTAssertEqual(picker("Chore object", in: app).value as? String, objectName)
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["chore-\(paused.id)"].exists)
        try tap(app.buttons["Add chore"], in: app)
        try fill(app.textFields["Chore name"], "Sweep after dinner")
        try choose("Weekly", from: "Repeat", in: app)
        try choose("One-off", from: "Repeat", in: app)
        try setSwitch(app.switches["Ada"], on: false, in: app)
        XCTAssertFalse(app.buttons["Create chore"].isEnabled)
        XCTAssertFalse(picker("Next turn", in: app).isEnabled)
        try setSwitch(app.switches["Ada"], on: true, in: app)
        try tap(app.buttons["Create chore"], in: app)
        XCTAssertTrue(app.staticTexts["Chore added."].waitForExistence(timeout: Wait.control))
        let added = try await choreState(home.id)
        let chore = try XCTUnwrap(added.items.first { $0.title == "Sweep after dinner" })
        XCTAssertNotNil(chore.dueDate)
        XCTAssertNil(chore.repeatDays)
        XCTAssertEqual(chore.componentId, objectChore.componentId)
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let completed = try await choreState(home.id)
        XCTAssertNil(completed.items.first { $0.id == chore.id }?.dueDate)
        XCTAssertEqual(completed.items.first { $0.id == chore.id }?.occurrence, 1)
        XCTAssertEqual(completed.history.filter { $0.choreId == chore.id }.count, 1)
        XCTAssertTrue(completed.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        XCTAssertTrue(app.buttons["Undo completion"].waitForExistence(timeout: Wait.control))
        try selectSegment("History", from: "chore-sections", in: app)
        XCTAssertTrue(app.staticTexts["Sweep after dinner"].waitForExistence(timeout: Wait.control))
        let completion = try XCTUnwrap(completed.history.first { $0.choreId == chore.id })
        try tap(app.otherElements["completion-\(completion.id)"].buttons["Undo completion"], in: app)
        XCTAssertTrue(app.staticTexts["Undo this chore completion?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Undo completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completion undone."].waitForExistence(timeout: Wait.control))
        let undone = try await choreState(home.id)
        XCTAssertEqual(undone.items.first { $0.id == chore.id }?.dueDate, chore.dueDate)
        XCTAssertEqual(undone.items.first { $0.id == chore.id }?.occurrence, 0)
        XCTAssertNotNil(undone.history.first { $0.id == completion.id }?.undoneAt)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Native object chores and undo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openChores(app)
        try selectSegment("History", from: "chore-sections", in: app)
        XCTAssertTrue(app.staticTexts["Sweep after dinner"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.staticTexts["Undone"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["completion-\(completion.id)"].buttons["Undo completion"].exists)
    }

    @MainActor
    func testChoresKeepFailedDraftsAndRequireConflictReview() async throws {
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        try tap(app.buttons["Add chore"], in: app)
        try fill(app.textFields["Chore name"], "Take out the recycling")
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "unavailable"])
        try tap(app.buttons["Create chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "Take out the recycling")
        XCTAssertFalse(picker("Repeat", in: app).isEnabled)
        XCTAssertFalse(app.staticTexts["Chore added."].exists)
        let failed = try await choreState(home.id)
        XCTAssertFalse(failed.items.contains { $0.title == "Take out the recycling" })
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore added."].waitForExistence(timeout: Wait.control))
        let added = try await choreState(home.id)
        let chore = try XCTUnwrap(added.items.first { $0.title == "Take out the recycling" })
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id])
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Record completion"].isEnabled)
        let conflicted = try await choreState(home.id)
        XCTAssertFalse(conflicted.history.contains { $0.choreId == chore.id })
        try tap(app.buttons["Review latest chores"], in: app)
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let completed = try await choreState(home.id)
        XCTAssertEqual(completed.history.filter { $0.choreId == chore.id }.count, 1)
        try tap(app.buttons["Undo completion"], in: app)
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id])
        try tap(app.buttons["Undo completion"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Undo completion"].isEnabled)
        XCTAssertFalse(app.staticTexts["Chore completion undone."].exists)
        let undoConflict = try await choreState(home.id)
        XCTAssertNil(undoConflict.history.first { $0.choreId == chore.id }?.undoneAt)
        try tap(app.buttons["Review latest chores"], in: app)
        try tap(app.buttons["Undo completion"], in: app)
        try tap(app.buttons["Undo completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completion undone."].waitForExistence(timeout: Wait.control))
        let undone = try await choreState(home.id)
        XCTAssertNotNil(undone.history.first { $0.choreId == chore.id }?.undoneAt)
        XCTAssertEqual(undone.items.first { $0.id == chore.id }?.dueDate, chore.dueDate)
    }

    @MainActor
    func testChoresRetryLostResponsesWithoutDuplicatingTheSave() async throws {
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        let before = try await choreState(home.id)
        try tap(app.buttons["Add chore"], in: app)
        try fill(app.textFields["Chore name"], "Clean the sink")
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Create chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Chore added."].exists)
        let unconfirmed = try await choreState(home.id)
        XCTAssertEqual(unconfirmed.items.filter { $0.title == "Clean the sink" }.count, 1)
        XCTAssertEqual(unconfirmed.version, before.version + 1)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore added."].waitForExistence(timeout: Wait.control))
        let confirmed = try await choreState(home.id)
        XCTAssertEqual(confirmed.items.filter { $0.title == "Clean the sink" }.count, 1)
        XCTAssertEqual(confirmed.version, unconfirmed.version)
        XCTAssertEqual(confirmed.requests.count, 2)
        XCTAssertNotNil(confirmed.requests.first?.mutationId)
        XCTAssertEqual(confirmed.requests.first?.mutationId, confirmed.requests.last?.mutationId)
        XCTAssertEqual(confirmed.requests.first?.mutationVersion, confirmed.requests.last?.mutationVersion)
        XCTAssertEqual(confirmed.requests.first?.version, confirmed.requests.last?.version)
        let chore = try XCTUnwrap(confirmed.items.first { $0.title == "Clean the sink" })
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let completed = try await choreState(home.id)
        try tap(app.buttons["Undo completion"], in: app)
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Undo completion"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Chore completion undone."].exists)
        let unconfirmedUndo = try await choreState(home.id)
        XCTAssertNotNil(unconfirmedUndo.history.first { $0.choreId == chore.id }?.undoneAt)
        XCTAssertEqual(unconfirmedUndo.version, completed.version + 1)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completion undone."].waitForExistence(timeout: Wait.control))
        let confirmedUndo = try await choreState(home.id)
        XCTAssertEqual(confirmedUndo.version, unconfirmedUndo.version)
        XCTAssertEqual(confirmedUndo.items.first { $0.id == chore.id }?.dueDate, chore.dueDate)
        XCTAssertEqual(confirmedUndo.history.filter { $0.choreId == chore.id }.count, 1)
        let attempts = Array(confirmedUndo.requests.suffix(2))
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotNil(attempts.first?.mutationId)
        XCTAssertEqual(attempts.first?.mutationId, attempts.last?.mutationId)
        XCTAssertEqual(attempts.first?.mutationVersion, attempts.last?.mutationVersion)
        XCTAssertEqual(attempts.first?.version, attempts.last?.version)
    }
}
