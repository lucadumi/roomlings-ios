import XCTest

extension AccountUITests {
    private struct HouseRulesState: Decodable {
        let version: Int
        let name: String
        let budget: Int
        let currency: String
    }

    @MainActor
    private func houseRulesState(_ home: Seed.Home) async throws -> HouseRulesState {
        try JSONDecoder().decode(HouseRulesState.self, from: await fixture(
            "_fixture/settings/state", body: ["householdId": home.id]
        ))
    }

    @MainActor
    private func openHouseRules(_ app: XCUIApplication) throws {
        try openAccount(app)
        try tap(app.buttons["open-house-rules"], in: app)
        XCTAssertTrue(app.buttons["save-house-rules"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func save(_ app: XCUIApplication, until outcome: XCUIElement) throws {
        try tap(app.buttons["save-house-rules"], in: app, until: outcome)
    }

    @MainActor
    func testHouseRulesSaveToTheSharedHouseholdAndReviewRemoteChanges() async throws {
        continueAfterFailure = false
        let email = "rules-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp()
        try signIn(app, email: email)
        if app.buttons["household-entry"].label != home.name {
            try openAccount(app)
            try tap(app.buttons["Open \(home.name)"], in: app)
            XCTAssertTrue(app.staticTexts[home.name].waitForExistence(timeout: Wait.control))
        }
        let before = try await houseRulesState(home)

        try openHouseRules(app)
        XCTAssertEqual(app.textFields["Household name"].value as? String, "Cedar House")
        XCTAssertEqual(app.textFields["Monthly grocery budget"].value as? String, "250.00")
        XCTAssertEqual(picker("Currency", in: app).value as? String, "EUR")
        try fill(app.textFields["Household name"], "Cedar Loft")
        try fill(app.textFields["Monthly grocery budget"], "312.50")
        try choose("GBP", from: "Currency", in: app)
        try save(app, until: app.staticTexts["House rules saved."])
        XCTAssertTrue(app.buttons["Open Cedar Loft"].waitForExistence(timeout: Wait.control))
        let saved = try await houseRulesState(home)
        XCTAssertEqual(saved.version, before.version + 1)
        XCTAssertEqual(saved.name, "Cedar Loft")
        XCTAssertEqual(saved.budget, 31_250)
        XCTAssertEqual(saved.currency, "GBP")

        // A roommate renames the household while this draft is open.
        try tap(app.buttons["open-house-rules"], in: app)
        try fill(app.textFields["Monthly grocery budget"], "400")
        _ = try await fixture("_fixture/settings/remote", body: ["householdId": home.id, "name": "Cedar Annex"])
        let error = app.staticTexts["account-error"]
        try save(app, until: error)
        XCTAssertEqual(error.label, "House rules changed elsewhere. Refresh house rules and review the latest state before trying again.")
        let unchanged = try await houseRulesState(home)
        XCTAssertEqual(unchanged.budget, 31_250)
        try tap(app.buttons["review-house-rules"], in: app)
        XCTAssertTrue(app.staticTexts["house-rules-conflict"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["save-house-rules"].isEnabled)
        try tap(app.buttons["Use the latest values"], in: app)
        XCTAssertEqual(app.textFields["Household name"].value as? String, "Cedar Annex")
        XCTAssertEqual(app.textFields["Monthly grocery budget"].value as? String, "312.50")
        try fill(app.textFields["Monthly grocery budget"], "400")
        try save(app, until: app.staticTexts["House rules saved."])
        let latest = try await houseRulesState(home)
        XCTAssertEqual(latest.name, "Cedar Annex")
        XCTAssertEqual(latest.budget, 40_000)
        XCTAssertEqual(latest.currency, "GBP")
    }
}
