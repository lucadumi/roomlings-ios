import XCTest

extension AccountUITests {
    private struct RoomStyleState: Decodable {
        let version: Int
        let roomStyle: String
    }

    @MainActor
    private func roomStyleState(_ home: Seed.Home) async throws -> RoomStyleState {
        try JSONDecoder().decode(RoomStyleState.self, from: await fixture(
            "_fixture/settings/state", body: ["householdId": home.id]
        ))
    }

    @MainActor
    func testOwnersApplyASharedRoomStyleFromAccount() async throws {
        continueAfterFailure = false
        let email = "style-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp()
        try signIn(app, email: email)
        if app.buttons["household-entry"].label != home.name {
            try openAccount(app)
            try tap(app.buttons["Open \(home.name)"], in: app)
            XCTAssertTrue(app.staticTexts[home.name].waitForExistence(timeout: Wait.control))
        }
        let before = try await roomStyleState(home)
        XCTAssertEqual(before.roomStyle, "clay")

        try openAccount(app)
        try tap(app.buttons["open-room-style"], in: app)
        let apply = app.buttons["apply-room-style"]
        XCTAssertTrue(apply.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(apply.isEnabled, "Applying the current style must not send a save.")
        XCTAssertTrue(app.buttons["room-style-clay"].isSelected)
        XCTAssertTrue((app.staticTexts["room-style-hint"].label).hasPrefix("Current shared look: Clay."))
        try tap(app.buttons["room-style-coastal"], in: app)
        XCTAssertTrue(app.buttons["room-style-coastal"].isSelected)
        try tap(apply, in: app, until: app.staticTexts["Room style saved for everyone."])
        let saved = try await roomStyleState(home)
        XCTAssertEqual(saved.roomStyle, "coastal")
        XCTAssertEqual(saved.version, before.version + 1)

        try tap(app.buttons["open-room-style"], in: app)
        XCTAssertTrue(app.buttons["room-style-coastal"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.buttons["room-style-coastal"].isSelected)
        XCTAssertEqual(app.buttons["room-style-coastal"].label, "Coastal, current")
    }
}
