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
        XCTAssertTrue(sheet.staticTexts["Supplies"].waitForExistence(timeout: Wait.control))
        try choose("Needs cleaning", from: "Manual state", in: app)
        XCTAssertTrue(app.staticTexts["Object state saved."].waitForExistence(timeout: Wait.control))
        let lastSet = sheet.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Set by Ada")).firstMatch
        XCTAssertTrue(lastSet.waitForExistence(timeout: Wait.control))
        attachObjectsScreenshot("Sink details")

        // A supply shortcut is reviewed, then added to the shared list once.
        try tap(sheet.buttons["Restock Dish soap"], in: app)
        XCTAssertTrue(app.staticTexts["Add to shopping list"].waitForExistence(timeout: Wait.control))
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
    func testRoomEditorPlacesObjectsInTheRoomAndAppliesThemForEveryone() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let email = "editor-\(UUID().uuidString.lowercased())@example.test"
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
        attachObjectsScreenshot("Kitchen before editing")
        try tap(app.buttons["room-objects-entry"], in: app)
        try tap(app.buttons["edit-room"], in: app)
        let editor = app.otherElements["room-editor-sheet"]
        XCTAssertTrue(editor.waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.staticTexts["room-editor-status"].label, "No unapplied changes.")

        // The stored kettle comes back through a placement preview in the live room.
        try selectSegment("Storage (1)", from: "room-editor-sections", in: app)
        try tap(app.buttons["Bring back Kettle"], in: app)
        let bar = app.otherElements["placement-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(editor.exists, "The editor steps aside while the placement is previewed.")
        attachObjectsScreenshot("Kettle placement preview")
        try tap(app.buttons["place-object"], in: app, until: editor)
        XCTAssertTrue(app.staticTexts["room-editor-notice"].label.hasPrefix("Kettle is kept in your private draft."))

        // A new object from the catalog, then a discarded trial that leaves the draft unchanged.
        try selectSegment("Add objects", from: "room-editor-sections", in: app)
        let search = app.textFields["Find an object"]
        try tap(search, in: app)
        search.typeText("Coffee machine\n")
        // The catalog grid is lazy: scroll its card into the sheet before using it.
        reveal(app.buttons["room-editor-catalog-coffee-machine"], in: editor)
        attachObjectsScreenshot("Editor catalog")
        try tap(app.buttons["room-editor-catalog-coffee-machine"], in: app, until: bar)
        try tap(app.buttons["discard-placement"], in: app, until: editor)
        XCTAssertEqual(app.staticTexts["room-editor-status"].label, "1 object has unapplied changes.")
        try tap(app.buttons["room-editor-catalog-coffee-machine"], in: app, until: bar)
        try tap(app.buttons["place-object"], in: app, until: editor)
        XCTAssertEqual(app.staticTexts["room-editor-status"].label, "2 objects have unapplied changes.")
        attachObjectsScreenshot("Editor draft")

        try tap(app.buttons["room-editor-apply"], in: app)
        XCTAssertTrue(editor.waitForNonExistence(timeout: Wait.control))
        XCTAssertTrue(app.webViews["room-renderer"].staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))

        // Both objects are saved for everyone: the objects list now shows them.
        try tap(app.buttons["room-objects-entry"], in: app)
        let sheet = app.otherElements["room-objects-sheet"]
        XCTAssertTrue(sheet.buttons["room-object-default-kitchen-kettle"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(reveal(sheet.buttons["Open Coffee machine details"], in: sheet))
        attachObjectsScreenshot("Applied room")

        // Putting the kettle back in Storage is applied the same way.
        try tap(sheet.buttons["Done"], in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: Wait.control))
        try tap(app.buttons["room-objects-entry"], in: app)
        try tap(app.buttons["edit-room"], in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Wait.control))
        reveal(editor.buttons["Edit Kettle"], in: editor)
        try tap(editor.buttons["Edit Kettle"], in: app)
        XCTAssertTrue(app.textFields["Object name"].waitForExistence(timeout: Wait.control))
        attachObjectsScreenshot("Editor object settings")
        try tap(app.buttons["room-editor-store"], in: app)
        XCTAssertTrue(app.staticTexts["room-editor-notice"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["room-editor-apply"], in: app)
        XCTAssertTrue(editor.waitForNonExistence(timeout: Wait.control))
        try tap(app.buttons["room-objects-entry"], in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(reveal(sheet.buttons["Open Coffee machine details"], in: sheet))
        XCTAssertFalse(sheet.buttons["room-object-default-kitchen-kettle"].exists)
    }

    /// Object grids are lazy, so a card below the fold exists only once it is scrolled into the sheet.
    @MainActor @discardableResult
    private func reveal(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        for _ in 0..<8 where !element.exists { container.swipeUp() }
        return element.exists
    }

    @MainActor
    private func attachObjectsScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
