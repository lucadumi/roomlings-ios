import XCTest

final class AccountUITests: XCTestCase {
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
        }
        struct Completion: Decodable {
            let id: String
            let choreId: String
            let title: String
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
    private func launchApp(systemControls: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = systemControls ? ["-roomlings-system-controls"] : []
        app.launchEnvironment["ROOMLINGS_API_ORIGIN"] = try fixtureOrigin().absoluteString
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
    private func fill(_ field: XCUIElement, _ value: String) throws {
        guard field.waitForExistence(timeout: Wait.control) else { throw FlowError.missingElement(field.description) }
        // A loaded simulator drops synthesized keystrokes while SwiftUI rebuilds the form, so
        // confirm what actually landed rather than trusting a single typeText.
        for _ in 1...3 {
            field.tap()
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
    private func tap(_ button: XCUIElement, in app: XCUIApplication) throws {
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
                    area.size.height = min(area.height, keyboardFrame.minY - area.minY - 44)
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
            let down = frame.midY < area.midY
            // Use the sheet's gutter so dragging cannot focus a text field or open a menu.
            let x = area.minX - appFrame.minX + 8
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: x, dy: area.minY - appFrame.minY + area.height * (down ? 0.2 : 0.8)))
            let end = origin.withOffset(CGVector(dx: x, dy: area.minY - appFrame.minY + area.height * (down ? 0.8 : 0.2)))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
    }

    @MainActor
    private func setSwitch(_ control: XCUIElement, on: Bool, in app: XCUIApplication) throws {
        guard control.exists || control.waitForExistence(timeout: Wait.control) else {
            throw FlowError.missingElement(control.description)
        }
        let wanted = on ? "1" : "0"
        for _ in 0..<3 {
            if control.value as? String == wanted { return }
            try tap(control, in: app)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wanted), object: control)
            if XCTWaiter.wait(for: [changed], timeout: Wait.flip) == .completed { return }
        }
        throw FlowError.missingElement("\(control.description) did not change to \(wanted)")
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
        guard XCTWaiter.wait(for: [signedIn], timeout: Wait.control) == .completed else {
            throw FlowError.missingElement("Signed-in account state")
        }
    }

    @MainActor
    private func openAccount(_ app: XCUIApplication) throws {
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
    private func openChores(_ app: XCUIApplication) throws {
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        let sheet = app.otherElements["chores-sheet"]
        let control = room.descendants(matching: .any).matching(identifier: "Chores").firstMatch
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
        XCTAssertTrue(app.staticTexts["Wipe the kitchen counters"].waitForExistence(timeout: Wait.control))
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
        XCTAssertEqual(mine.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try tap(mine, in: app)
        XCTAssertEqual(mine.value as? String, "0")
        try tap(app.segmentedControls["chore-sections"].buttons["Archived"], in: app)
        XCTAssertTrue(app.staticTexts["No archived chores."].waitForExistence(timeout: Wait.control))
        try tap(app.segmentedControls["chore-sections"].buttons["Chores"], in: app)
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
        let mine = app.switches["My turn only"]
        XCTAssertTrue(mine.waitForExistence(timeout: Wait.control))
        let nativeSwitch = mine.switches.firstMatch.exists ? mine.switches.firstMatch : mine
        try tap(nativeSwitch, in: app)
        XCTAssertEqual(value.label, "Bathroom|on|Chores")
        try tap(nativeSwitch, in: app)
        XCTAssertEqual(value.label, "Bathroom|off|Chores")
        let segments = app.segmentedControls["fixture-segments"]
        try tap(segments.buttons["History"], in: app)
        XCTAssertEqual(value.label, "Bathroom|off|History")
        let enable = app.switches["Enable controls"]
        let nativeEnable = enable.switches.firstMatch.exists ? enable.switches.firstMatch : enable
        try tap(nativeEnable, in: app)
        XCTAssertEqual(enable.value as? String, "0")
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
        executionTimeAllowance = 300
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        try exerciseChoreControls(app, screenshotName: "Roomlings control styling trial")
        let initial = try await choreState(home.id)
        let paused = try XCTUnwrap(initial.items.first { $0.title == "Clean the stored kettle" })
        XCTAssertFalse(app.otherElements["chore-\(paused.id)"].buttons["Mark done"].isEnabled)
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
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let completed = try await choreState(home.id)
        XCTAssertNil(completed.items.first { $0.id == chore.id }?.dueDate)
        XCTAssertEqual(completed.items.first { $0.id == chore.id }?.occurrence, 1)
        XCTAssertEqual(completed.history.filter { $0.choreId == chore.id }.count, 1)
        XCTAssertTrue(completed.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        try tap(app.segmentedControls["chore-sections"].buttons["History"], in: app)
        XCTAssertTrue(app.staticTexts["Sweep after dinner"].waitForExistence(timeout: Wait.control))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Native shared chores history"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openChores(app)
        try tap(app.segmentedControls["chore-sections"].buttons["History"], in: app)
        XCTAssertTrue(app.staticTexts["Sweep after dinner"].waitForExistence(timeout: Wait.control))
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
    }
}
