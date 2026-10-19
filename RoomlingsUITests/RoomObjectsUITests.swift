import XCTest

extension AccountUITests {
    @MainActor
    func testRoomObjectsShowDetailsSaveStatesAndRestockSupplies() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let email = "objects-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp()
        try signIn(app, email: email)
        if app.buttons["household-entry"].label != home.name {
            try openAccount(app)
            try tap(app.buttons["Open \(home.name)"], in: app)
            XCTAssertTrue(app.staticTexts[home.name].waitForExistence(timeout: Wait.control))
        }
        XCTAssertTrue(app.webViews["room-renderer"].staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        try tap(app.buttons["room-objects-entry"], in: app)
        let sheet = app.otherElements["room-objects-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(sheet.staticTexts["Kitchen objects"].exists)
        // The stored kettle is not placed, so the list leaves it out.
        XCTAssertFalse(sheet.buttons["room-object-default-kitchen-kettle"].exists)
        attachObjectsScreenshot("Kitchen objects")

        // Linked chores show on their object.
        try tap(sheet.buttons["room-object-default-kitchen-fridge"], in: app)
        XCTAssertTrue(sheet.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        try tap(sheet.buttons["All room objects"], in: app)

        try tap(sheet.buttons["room-object-default-kitchen-sink"], in: app)
        XCTAssertTrue(sheet.staticTexts["Supply shortcuts"].waitForExistence(timeout: Wait.control))
        try choose("Needs cleaning", from: "Manual state", in: app)
        XCTAssertTrue(app.staticTexts["Object state saved."].waitForExistence(timeout: Wait.control))
        let lastSet = sheet.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last set by Ada")).firstMatch
        XCTAssertTrue(lastSet.waitForExistence(timeout: Wait.control))
        attachObjectsScreenshot("Sink details")

        // A supply shortcut is reviewed, then added to the shared list once.
        try tap(sheet.buttons["Restock Dish soap"], in: app)
        XCTAssertTrue(app.staticTexts["Restock a household supply."].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Quantity"].value as? String, "1 bottle")
        try tap(app.buttons["Add item"], in: app)
        XCTAssertTrue(app.staticTexts["Supply added to shopping list."].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(sheet.staticTexts["1 bottle already on the shared list"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(sheet.buttons["Restock Dish soap"].exists)

        // The list keeps the state, and a suggested routine opens a prefilled chore.
        try tap(sheet.buttons["All room objects"], in: app)
        XCTAssertTrue(sheet.staticTexts["Manual state: Needs cleaning"].waitForExistence(timeout: Wait.control))
        try tap(sheet.buttons["room-object-default-kitchen-sink"], in: app)
        try tap(sheet.buttons["Add Clean the sink"], in: app)
        XCTAssertTrue(app.otherElements["chores-sheet"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "Clean the sink")
    }

    @MainActor
    private func attachObjectsScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
