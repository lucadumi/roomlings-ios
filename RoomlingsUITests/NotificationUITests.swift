import XCTest

extension AccountUITests {
    @MainActor
    func testNotificationWaitsForSignInBeforeOpeningItsAuthorizedHousehold() async throws {
        executionTimeAllowance = 360
        continueAfterFailure = false
        let email = "notification-sign-in-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Willow House" })
        let payload = try notificationPayload(
            householdID: home.id, kind: "chores", entryField: "componentId", entryID: "default-kitchen-fridge"
        )
        let app = try launchApp(notificationPayload: payload)
        XCTAssertTrue(app.staticTexts["pending-notification"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["chores-sheet"].exists)
        try signIn(app, email: email)
        XCTAssertTrue(app.otherElements["chores-sheet"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["household-entry"].label, home.name)
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        try await waitForAnalytics("notification_opened", count: 1, homes: [home])
        try tap(app.buttons["Done"], in: app)
    }

    @MainActor
    func testNotificationMutesPersistAfterRelaunchWithoutPermissionOrDeliveryConfiguration() async throws {
        executionTimeAllowance = 360
        continueAfterFailure = false
        let email = "notification-settings-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/seed", body: ["email": email])
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        let choreSwitch = app.switches["notification-chores"]
        let moneySwitch = app.switches["notification-money"]
        XCTAssertTrue(choreSwitch.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(moneySwitch.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.staticTexts["push-unavailable"].exists)
        XCTAssertFalse(app.buttons["enable-notifications"].isEnabled)
        try setSwitch(choreSwitch, on: false, in: app)
        try setSwitch(moneySwitch, on: false, in: app)
        try tap(app.buttons["Done"], in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["account-entry"].waitForExistence(timeout: Wait.control))
        try openAccount(app)
        XCTAssertTrue(choreSwitch.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(try switchIsOn(choreSwitch))
        XCTAssertFalse(try switchIsOn(moneySwitch))
        XCTAssertFalse(app.buttons["enable-notifications"].isEnabled)
        try setSwitch(choreSwitch, on: true, in: app)
        XCTAssertFalse(try switchIsOn(moneySwitch))
        attachHeaderScreenshot("Saved notification preferences without APNs credentials")
        try tap(app.buttons["Done"], in: app)
    }

    @MainActor
    func testNotificationRoutingSelectsTheAccessibleHouseholdAndShowsTheActualReceiptAndObject() async throws {
        executionTimeAllowance = 360
        continueAfterFailure = false
        let email = "notification-route-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        _ = try await fixture("_fixture/shopping/seed", body: ["householdId": home.id, "invitation": seed.invitation])
        for _ in 0..<8 {
            _ = try await fixture("_fixture/ledger/remote", body: ["householdId": home.id])
        }
        let ledger = try await ledgerState(home)
        let expense = try XCTUnwrap(ledger.expenses.last)
        let app = try launchApp()
        try signIn(app, email: email)
        app.terminate()
        app.launchEnvironment["ROOMLINGS_NOTIFICATION_PAYLOAD"] = try notificationPayload(
            householdID: home.id, kind: "expense", entryField: "expenseId", entryID: expense.id
        )
        app.launch()
        XCTAssertTrue(app.otherElements["money-sheet"].waitForExistence(timeout: Wait.control))
        let receipt = app.otherElements["receipt-\(expense.id)"]
        XCTAssertTrue(receipt.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(receipt.isHittable, "The notification must reveal its receipt rather than only opening Money.")
        XCTAssertEqual(app.buttons["household-entry"].label, home.name)
        try await waitForAnalytics("notification_opened", count: 1, homes: [home])
        attachHeaderScreenshot("Notification opened the recorded receipt")
        try tap(app.buttons["Done"], in: app)
        app.terminate()
        app.launchEnvironment["ROOMLINGS_NOTIFICATION_PAYLOAD"] = try notificationPayload(
            householdID: home.id, kind: "chores", entryField: "componentId", entryID: "default-kitchen-fridge"
        )
        app.launch()
        XCTAssertTrue(app.otherElements["chores-sheet"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["household-entry"].label, home.name)
        try await waitForAnalytics("notification_opened", count: 2, homes: [home])
        try tap(app.buttons["Done"], in: app)
    }

    @MainActor
    func testUnrelatedAndDeletedNotificationTargetsCannotExposeAnotherHouseholdOrPretendToOpenAnEntry() async throws {
        executionTimeAllowance = 360
        continueAfterFailure = false
        let email = "notification-denied-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let app = try launchApp()
        try signIn(app, email: email)
        let originalHousehold = app.buttons["household-entry"].label
        app.terminate()
        app.launchEnvironment["ROOMLINGS_NOTIFICATION_PAYLOAD"] = try notificationPayload(
            householdID: UUID().uuidString, kind: "chores"
        )
        app.launch()
        XCTAssertTrue(app.staticTexts["That notification no longer belongs to a household you can access."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["household-entry"].label, originalHousehold)
        XCTAssertFalse(app.otherElements["chores-sheet"].exists)
        let home = try XCTUnwrap(seed.homes.first)
        app.terminate()
        app.launchEnvironment["ROOMLINGS_NOTIFICATION_PAYLOAD"] = try notificationPayload(
            householdID: home.id, kind: "settlement", entryField: "settlementId", entryID: UUID().uuidString
        )
        app.launch()
        XCTAssertTrue(app.staticTexts["That repayment is no longer available. Open Money to review the current ledger."]
            .waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.otherElements["money-sheet"].exists)
        let analytics = try await analyticsState(seed.homes)
        XCTAssertEqual(analytics.occurrences("notification_opened"), 0)
        try tap(app.buttons["Done"], in: app)
    }

    private func notificationPayload(
        householdID: String, kind: String, entryField: String? = nil, entryID: String? = nil
    ) throws -> String {
        var fields: [String: Any] = ["version": 1, "householdId": householdID, "kind": kind]
        if let entryField, let entryID { fields[entryField] = entryID }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}
