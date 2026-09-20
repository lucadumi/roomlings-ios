import XCTest

extension AccountUITests {
    struct AnalyticsState: Decodable {
        struct Row: Decodable {
            let householdId: String
            let memberId: String
            let kind: String
            let localDate: String
            let occurrences: Int
        }
        struct Request: Decodable {
            struct Event: Decodable {
                let kind: String
                let occurredAt: String
                let localDate: String
                let extraKeys: [String]
            }
            let householdId: String
            let keys: [String]
            let events: [Event]
            let native: Bool
            let browserHeaders: Bool
            let status: Int?
        }
        let rows: [Row]
        let requests: [Request]

        func occurrences(_ kind: String) -> Int {
            rows.filter { $0.kind == kind }.reduce(0) { $0 + $1.occurrences }
        }
    }

    @MainActor
    func analyticsState(_ homes: [Seed.Home]) async throws -> AnalyticsState {
        try JSONDecoder().decode(AnalyticsState.self, from: await fixture(
            "_fixture/analytics/state", body: ["householdIds": homes.map(\.id)]
        ))
    }

    @MainActor
    @discardableResult
    func waitForAnalytics(_ kind: String, count: Int, homes: [Seed.Home]) async throws -> AnalyticsState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Wait.control))
        var state = try await analyticsState(homes)
        while state.occurrences(kind) < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            state = try await analyticsState(homes)
        }
        XCTAssertEqual(state.occurrences(kind), count)
        return state
    }

    @MainActor
    func testAnalyticsCountsForegroundVisitsButNotSheetRefreshes() async throws {
        continueAfterFailure = false
        let email = "analytics-open-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let app = try launchApp()
        let signedOut = try await analyticsState(seed.homes)
        XCTAssertTrue(signedOut.rows.isEmpty)
        XCTAssertTrue(signedOut.requests.isEmpty)
        try signIn(app, email: email)
        let first = try await waitForAnalytics("app_opened", count: 1, homes: seed.homes)
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertNotNil(UUID(uuidString: first.rows[0].memberId))
        try openAccount(app)
        try tap(app.buttons["Done"], in: app)
        let refreshed = try await analyticsState(seed.homes)
        XCTAssertEqual(refreshed.occurrences("app_opened"), 1)
        XCUIDevice.shared.press(.home)
        app.activate()
        let second = try await waitForAnalytics("app_opened", count: 2, homes: seed.homes)
        XCTAssertTrue(second.rows.allSatisfy { $0.memberId == first.rows[0].memberId })
        XCTAssertEqual(second.requests.count, 2)
        let days = Set(second.requests.flatMap(\.events).map(\.localDate))
        XCTAssertEqual(second.rows.count, days.count)
        for request in second.requests {
            XCTAssertEqual(request.keys, ["events"])
            XCTAssertTrue(request.native)
            XCTAssertFalse(request.browserHeaders)
            XCTAssertEqual(request.status, 200)
            XCTAssertEqual(request.events.count, 1)
            let event = try XCTUnwrap(request.events.first)
            XCTAssertEqual(event.kind, "app_opened")
            XCTAssertTrue(event.extraKeys.isEmpty)
            let row = try XCTUnwrap(second.rows.first {
                $0.householdId == request.householdId && $0.localDate == event.localDate
            })
            XCTAssertEqual(row.occurrences, second.requests.flatMap(\.events).filter { $0.localDate == row.localDate }.count)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            XCTAssertNotNil(formatter.date(from: event.occurredAt))
        }
        XCTAssertEqual(app.buttons["household-entry"].value as? String, "Household loaded")
    }

    @MainActor
    func testAnalyticsLostResponseDoesNotRetryOrHideHouseholdTools() async throws {
        continueAfterFailure = false
        let email = "analytics-lost-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        _ = try await fixture("_fixture/analytics/failure", body: ["mode": "lost-response"])
        let app = try launchApp()
        try signIn(app, email: email)
        try await waitForAnalytics("app_opened", count: 1, homes: seed.homes)
        try openAccount(app)
        XCTAssertFalse(app.staticTexts["account-error"].exists)
        try tap(app.buttons["Done"], in: app)
        try openMoney(app)
        try tap(app.buttons["Done"], in: app)
        try openShopping(app)
        try tap(app.buttons["Done"], in: app)
        try openChores(app)
        try tap(app.buttons["Done"], in: app)
        let state = try await analyticsState(seed.homes)
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(state.occurrences("app_opened"), 1)
        XCTAssertEqual(app.buttons["household-entry"].value as? String, "Household loaded")
    }
}
