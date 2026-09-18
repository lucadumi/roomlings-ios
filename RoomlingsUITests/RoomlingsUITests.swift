import XCTest

final class RoomlingsUITests: XCTestCase {
    @MainActor
    private func tapControl(_ control: XCUIElement) {
        if !control.isHittable {
            let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: Wait.flip), .completed, control.debugDescription)
        }
        control.tap()
    }

    /// Taps a room control until the renderer proves it reacted. A busy web renderer can
    /// swallow a synthesized touch, and the room still reporting `previous` is proof that
    /// nothing moved, so another tap cannot overshoot the wanted state.
    @MainActor
    private func tapRoom(_ control: XCUIElement, until wanted: XCUIElement,
                         while previous: XCUIElement, _ message: String) {
        XCTAssertTrue(control.waitForExistence(timeout: Wait.room), message)
        for _ in 1...4 {
            tapControl(control)
            if wanted.waitForExistence(timeout: Wait.flip) { return }
            // Anything other than the old state means the tap landed, so stop tapping and
            // give the renderer the long budget to finish settling.
            if !previous.exists { break }
        }
        XCTAssertTrue(wanted.waitForExistence(timeout: Wait.room), message)
    }

    @MainActor
    func testSharedKitchenLoadsOfflineAndItsControlsWork() throws {
        // Software-rendered simulators need time for the full gesture and orientation flow.
        executionTimeAllowance = 360
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROOMLINGS_API_ORIGIN"] = "http://127.0.0.1:1"
        app.launchEnvironment["ROOMLINGS_KEYCHAIN_SERVICE"] = "com.roomlings.room-test.\(UUID().uuidString)"
        app.launch()
        XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: Wait.control))
        app.buttons["Not now"].tap()
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.waitForExistence(timeout: Wait.room))
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        XCTAssertEqual(room.frame.minY, app.frame.minY, accuracy: 1)
        XCTAssertEqual(room.frame.maxY, app.frame.maxY, accuracy: 1)
        XCTAssertEqual(room.frame.width, app.frame.width, accuracy: 1)
        let zoomIn = room.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: Wait.room))
        XCTAssertFalse(app.staticTexts["Room unavailable"].exists)
        XCTAssertFalse(room.buttons["Hide object labels"].exists)
        XCTAssertFalse(room.buttons["Room chores"].exists)
        XCTAssertFalse(room.descendants(matching: .any).matching(identifier: "Chores").firstMatch.exists)
        XCTAssertFalse(room.descendants(matching: .any).matching(identifier: "Shopping").firstMatch.exists)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Kitchen portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
        let evening = room.switches["Switch to evening lighting"]
        let daylight = room.switches["Switch to daylight"]
        let reset = room.switches["Reset room view"]
        let restored = room.staticTexts["100"]
        let moved = room.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+' AND label != '100'")).firstMatch
        tapRoom(evening, until: daylight, while: evening, "Lighting must respond before any camera gestures.")
        tapRoom(daylight, until: evening, while: daylight, "Lighting must return to daylight.")
        tapRoom(zoomIn, until: room.staticTexts["110"], while: restored, "Zooming in must change the room zoom.")
        tapRoom(reset, until: restored, while: moved, "Resetting must return the room to its default zoom.")
        room.pinch(withScale: 1.3, velocity: 0.5)
        XCTAssertTrue(moved.waitForExistence(timeout: Wait.room), "Pinching must change the room zoom, not magnify the web page.")
        tapRoom(reset, until: restored, while: moved, "Resetting must undo a pinch.")
        tapRoom(evening, until: daylight, while: evening, "Lighting must remain responsive after pinching.")
        tapRoom(daylight, until: evening, while: daylight, "Lighting must return to daylight after pinching.")
        let fridgeOpen = room.switches["Close the fridge"]
        let fridgeShut = room.switches["Peek inside"]
        let kettle = room.switches["Put the kettle on"]
        let brewing = room.switches.matching(NSPredicate(format: "label == %@ AND value == %@", "Put the kettle on", "1")).firstMatch
        let idle = room.switches.matching(NSPredicate(format: "label == %@ AND value == %@", "Put the kettle on", "0")).firstMatch
        tapRoom(fridgeOpen, until: fridgeShut, while: fridgeOpen, "The fridge door must close.")
        tapRoom(fridgeShut, until: fridgeOpen, while: fridgeShut, "The fridge door must open again.")
        XCTAssertTrue(idle.waitForExistence(timeout: Wait.room), "The kettle must start out idle.")
        tapRoom(kettle, until: brewing, while: idle, "The kettle must start brewing.")
        let start = room.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        let end = room.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = room.frame
            return frame.width > frame.height
        }, object: room)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: Wait.room), .completed,
                       "The room viewer should settle into landscape after rotation.")
        let roomFrame = room.frame
        let appFrame = app.frame
        XCTAssertEqual(roomFrame.minX, appFrame.minX, accuracy: 1)
        XCTAssertEqual(roomFrame.maxX, appFrame.maxX, accuracy: 1)
        XCTAssertTrue(zoomIn.waitForExistence(timeout: Wait.room))
        XCTAssertTrue(zoomIn.isHittable)
        tapRoom(reset, until: restored, while: moved, "Resetting must work in landscape.")
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Kitchen landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(reset.waitForExistence(timeout: Wait.room))
        XCTAssertFalse(app.staticTexts["Room unavailable"].exists)
    }
}
