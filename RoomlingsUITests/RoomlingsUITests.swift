import XCTest

final class RoomlingsUITests: XCTestCase {
    @MainActor
    private func tapControl(_ control: XCUIElement) {
        XCTAssertTrue(control.isHittable)
        control.tap()
    }

    @MainActor
    func testSharedKitchenLoadsOfflineAndItsControlsWork() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROOMLINGS_API_ORIGIN"] = "http://127.0.0.1:1"
        app.launchEnvironment["ROOMLINGS_KEYCHAIN_SERVICE"] = "com.roomlings.room-test.\(UUID().uuidString)"
        app.launch()
        XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: 15))
        app.buttons["Not now"].tap()
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.waitForExistence(timeout: 30))
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: 45))
        XCTAssertEqual(room.frame.minY, app.frame.minY, accuracy: 1)
        XCTAssertEqual(room.frame.maxY, app.frame.maxY, accuracy: 1)
        XCTAssertEqual(room.frame.width, app.frame.width, accuracy: 1)
        let zoomIn = room.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 45))
        XCTAssertFalse(app.staticTexts["Room unavailable"].exists)
        XCTAssertFalse(room.buttons["Hide object labels"].exists)
        XCTAssertFalse(room.buttons["Room chores"].exists)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Kitchen portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
        tapControl(room.switches["Switch to evening lighting"])
        XCTAssertTrue(room.switches["Switch to daylight"].waitForExistence(timeout: 10), "Lighting must respond before any camera gestures.")
        tapControl(room.switches["Switch to daylight"])
        zoomIn.tap()
        XCTAssertTrue(room.staticTexts["110"].waitForExistence(timeout: 10))
        tapControl(room.switches["Reset room view"])
        XCTAssertTrue(room.staticTexts["100"].waitForExistence(timeout: 10))
        room.pinch(withScale: 1.3, velocity: 0.5)
        let changedZoom = room.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+' AND label != '100'")).firstMatch
        XCTAssertTrue(changedZoom.waitForExistence(timeout: 10), "Pinching must change the room zoom, not magnify the web page.")
        tapControl(room.switches["Reset room view"])
        tapControl(room.switches["Switch to evening lighting"])
        XCTAssertTrue(room.switches["Switch to daylight"].waitForExistence(timeout: 10), "Lighting must remain responsive after pinching.")
        tapControl(room.switches["Switch to daylight"])
        tapControl(room.switches["Close the fridge"])
        XCTAssertTrue(room.switches["Peek inside"].waitForExistence(timeout: 10))
        tapControl(room.switches["Peek inside"])
        let kettle = room.switches["Put the kettle on"]
        tapControl(kettle)
        let brewing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: kettle)
        XCTAssertEqual(XCTWaiter.wait(for: [brewing], timeout: 10), .completed)
        let start = room.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        let end = room.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            room.frame.width > room.frame.height
        }, object: room)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        XCTAssertEqual(room.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(room.frame.maxX, app.frame.maxX, accuracy: 1)
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 10))
        XCTAssertTrue(zoomIn.isHittable)
        tapControl(room.switches["Reset room view"])
        XCTAssertTrue(room.staticTexts["100"].waitForExistence(timeout: 10))
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Kitchen landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(room.switches["Reset room view"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Room unavailable"].exists)
    }
}
