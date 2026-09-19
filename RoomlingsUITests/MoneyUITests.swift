import XCTest

extension AccountUITests {
    struct LedgerState: Decodable {
        struct Expense: Decodable {
            let id: String
            let description: String
            let amount: Int
            let paidBy: String
            let participants: [String]
            let category: String
            let date: String
            let shoppingRunId: String?
        }
        struct Run: Decodable {
            struct Archived: Decodable {
                let id: String
                let name: String
            }
            let id: String
            let expenseId: String
            let items: [Archived]
        }
        struct Settlement: Decodable {
            let id: String
            let from: String
            let to: String
            let amount: Int
        }
        struct Item: Decodable {
            let id: String
            let name: String
            let pickedUp: Bool
        }
        struct Request: Decodable {
            let method: String
            let native: Bool
            let browserHeaders: Bool
            let mutationId: String?
        }
        let version: Int
        let expenses: [Expense]
        let runs: [Run]
        let items: [Item]
        let settlements: [Settlement]
        let requests: [Request]
        /// The shared server's own balance calculation, which iOS must match exactly.
        let balances: [String: Int]
    }

    @MainActor
    func ledgerState(_ home: Seed.Home) async throws -> LedgerState {
        try JSONDecoder().decode(LedgerState.self, from: await fixture("_fixture/ledger/state", body: ["householdId": home.id]))
    }

    /// Submits the receipt form. The long form puts its primary action below the fold, and
    /// dismissing the decimal keyboard can swallow the first tap. The form still being shown
    /// with no error is proof the save never started, so tapping again cannot record twice.
    @MainActor
    func submitReceipt(_ app: XCUIApplication, expecting text: String, sheet: String) throws {
        let submit = app.buttons["record-receipt"]
        for _ in 0..<3 {
            try tap(submit, in: app)
            if app.staticTexts[text].waitForExistence(timeout: Wait.flip) { return }
            guard submit.exists, !app.staticTexts["\(sheet)-error"].exists,
                  !app.staticTexts["receipt-form-error"].exists else { break }
        }
        expectNotice(text, in: app, sheet: sheet)
    }

    /// Reports whatever the sheet is showing instead, so a failed save names its own reason.
    @MainActor
    func expectNotice(_ text: String, in app: XCUIApplication, sheet: String) {
        if app.staticTexts[text].waitForExistence(timeout: Wait.control) { return }
        let sheetError = app.staticTexts["\(sheet)-error"]
        let formError = app.staticTexts["receipt-form-error"]
        XCTFail("""
            "\(text)" never appeared.
            sheet error: \(sheetError.exists ? sheetError.label : "none")
            form error: \(formError.exists ? formError.label : "none")
            retry offered: \(app.buttons["Retry save"].exists)
            """)
    }

    @MainActor
    private func openMoney(_ app: XCUIApplication) throws {
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        let button = room.descendants(matching: .any).matching(identifier: "Money").firstMatch
        let sheet = app.otherElements["money-sheet"]
        for _ in 0..<3 {
            try tap(button, in: app)
            if sheet.waitForExistence(timeout: Wait.flip) {
                if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertLessThan(sheet.frame.width, app.frame.width) }
                return
            }
        }
        XCTFail("The Money dock button did not open its native sheet.")
    }

    @MainActor
    private func launchMoney() async throws -> (XCUIApplication, Seed.Home) {
        let email = "money-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        _ = try await fixture("_fixture/shopping/seed", body: ["householdId": home.id, "invitation": seed.invitation])
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openMoney(app)
        XCTAssertTrue(app.staticTexts["Roomlings only tracks what everyone owes. It never moves money between you."]
            .waitForExistence(timeout: Wait.control))
        return (app, home)
    }

    @MainActor
    private func openSection(_ name: String, in app: XCUIApplication) throws {
        try selectSegment(name, from: "money-sections", in: app)
    }

    @MainActor
    func testMoneyRecordsAReceiptKeepsFailedDraftsAndRemovesIt() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchMoney()
        let opening = try await ledgerState(home)
        XCTAssertTrue(opening.expenses.isEmpty)
        try openSection("Receipts", in: app)
        XCTAssertTrue(app.staticTexts["No receipts yet."].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["record-expense"], in: app)
        try fill(app.textFields["Receipt name"], "Corner shop")
        try fill(app.textFields["Amount"], "10.01")
        XCTAssertTrue(app.staticTexts["The server records the same whole-cent split."].waitForExistence(timeout: Wait.control))
        _ = try await fixture("_fixture/ledger/failure", body: ["mode": "unavailable"])
        try submitReceipt(app, expecting: "money-error", sheet: "money")
        XCTAssertFalse(app.staticTexts["Receipt recorded."].exists)
        XCTAssertEqual(app.textFields["Receipt name"].value as? String, "Corner shop")
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        let failed = try await ledgerState(home)
        XCTAssertTrue(failed.expenses.isEmpty)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Receipt recorded."].waitForExistence(timeout: Wait.control))
        let recorded = try await ledgerState(home)
        let expense = try XCTUnwrap(recorded.expenses.first { $0.description == "Corner shop" })
        // The phone must store whole cents, never a rounded decimal.
        XCTAssertEqual(expense.amount, 1001)
        XCTAssertNil(expense.shoppingRunId)
        XCTAssertEqual(expense.participants.count, 2)
        XCTAssertEqual(recorded.expenses.filter { $0.description == "Corner shop" }.count, 1)
        XCTAssertTrue(recorded.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        XCTAssertTrue(app.otherElements["receipt-\(expense.id)"].waitForExistence(timeout: Wait.control))
        try tap(app.otherElements["receipt-\(expense.id)"].buttons["Remove Corner shop"], in: app)
        XCTAssertTrue(app.staticTexts["Remove this receipt?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-remove-receipt"], in: app)
        XCTAssertTrue(app.staticTexts["Receipt removed from the ledger."].waitForExistence(timeout: Wait.control))
        let removed = try await ledgerState(home)
        XCTAssertFalse(removed.expenses.contains { $0.id == expense.id })
        XCTAssertEqual(removed.balances.values.reduce(0, +), 0)
    }

    @MainActor
    func testBalancesMatchTheServerAndRepaymentsCanBeUndone() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchMoney()
        XCTAssertTrue(app.staticTexts["Everyone is settled up."].waitForExistence(timeout: Wait.control))
        try openSection("Receipts", in: app)
        try tap(app.buttons["record-expense"], in: app)
        try fill(app.textFields["Receipt name"], "Big shop")
        try fill(app.textFields["Amount"], "10.01")
        try submitReceipt(app, expecting: "Receipt recorded.", sheet: "money")
        try openSection("Balances", in: app)
        let owed = try await ledgerState(home)
        // 1001 split two ways leaves an odd cent, so the balances prove whole-cent handling.
        XCTAssertEqual(owed.balances.values.reduce(0, +), 0)
        let nonZero = owed.balances.values.filter { $0 != 0 }.sorted()
        XCTAssertEqual(nonZero.count, 2)
        XCTAssertEqual(nonZero[0], -nonZero[1])
        XCTAssertTrue([500, 501].contains(nonZero[1]), "1001 split two ways must be 500 or 501, got \(nonZero[1]).")
        for (member, amount) in owed.balances where amount != 0 {
            let card = app.otherElements["balance-\(member)"]
            XCTAssertTrue(card.waitForExistence(timeout: Wait.control))
            let expected = amount > 0 ? "Is owed" : "Owes"
            XCTAssertTrue(card.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", expected)).firstMatch.exists,
                          "Balance card for \(member) must say \(expected).")
        }
        let debtor = try XCTUnwrap(owed.balances.first { $0.value < 0 }?.key)
        let creditor = try XCTUnwrap(owed.balances.first { $0.value > 0 }?.key)
        let suggestion = app.otherElements["transfer-\(debtor)-\(creditor)"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: Wait.control),
                      "The suggested repayment must match the server's own balance direction.")
        try tap(suggestion.buttons.firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Record a repayment."].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-repayment"], in: app)
        XCTAssertTrue(app.staticTexts["Repayment recorded. Roomlings tracks it; no money moved."]
            .waitForExistence(timeout: Wait.control))
        let settled = try await ledgerState(home)
        let repayment = try XCTUnwrap(settled.settlements.first)
        XCTAssertEqual(repayment.from, debtor)
        XCTAssertEqual(repayment.to, creditor)
        XCTAssertEqual(repayment.amount, nonZero[1])
        XCTAssertTrue(settled.balances.values.allSatisfy { $0 == 0 })
        XCTAssertTrue(app.staticTexts["Everyone is settled up."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(suggestion.exists)
        try tap(app.otherElements["settlement-\(repayment.id)"].buttons.firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Undo this repayment?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-undo-repayment"], in: app)
        XCTAssertTrue(app.staticTexts["Repayment undone."].waitForExistence(timeout: Wait.control))
        let undone = try await ledgerState(home)
        XCTAssertTrue(undone.settlements.isEmpty)
        XCTAssertEqual(undone.balances, owed.balances)
        XCTAssertTrue(app.otherElements["transfer-\(debtor)-\(creditor)"].waitForExistence(timeout: Wait.control))
    }
}
