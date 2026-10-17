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
    func openMoney(_ app: XCUIApplication) throws {
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

    struct BillsState: Decodable {
        struct Bill: Decodable {
            struct Revision: Decodable {
                let fromMonth: String
                let name: String
                let amount: Int
                let dueDay: Int
                let participants: [String]
            }
            struct Pause: Decodable {
                let fromMonth: String
                let untilMonth: String?
            }
            let id: String
            let startMonth: String
            let revisions: [Revision]
            let pauses: [Pause]
        }
        struct Payment: Decodable {
            struct Reference: Decodable {
                let billId: String
                let month: String
            }
            let id: String
            let amount: Int
            let bill: Reference
        }
        struct Request: Decodable {
            let path: String
            let native: Bool
            let browserHeaders: Bool
            let mutationId: String?
        }
        let billingTimeZone: String
        let bills: [Bill]
        let payments: [Payment]
        let requests: [Request]
    }

    @MainActor
    func billsState(_ home: Seed.Home) async throws -> BillsState {
        try JSONDecoder().decode(BillsState.self, from: await fixture("_fixture/bills/state", body: ["householdId": home.id]))
    }

    @MainActor
    func testBillsFollowTheSharedScheduleAndUndoPaymentsNatively() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchMoney()
        try openSection("Bills", in: app)
        XCTAssertTrue(app.staticTexts["Make room for the regulars."].waitForExistence(timeout: Wait.control))

        // The first bill sets the household's billing time zone from this device, as on the web.
        try tap(app.buttons["new-bill"], in: app)
        XCTAssertTrue(app.staticTexts["A regular part of home."].waitForExistence(timeout: Wait.control))
        try fill(app.textFields["Bill name"], "Internet")
        try fill(app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Default amount")).firstMatch, "42.01")
        try tap(app.buttons["confirm-bill"], in: app, until: app.staticTexts["Monthly bill created."])
        let created = try await billsState(home)
        let bill = try XCTUnwrap(created.bills.first)
        XCTAssertEqual(created.billingTimeZone, TimeZone.current.identifier)
        XCTAssertEqual(bill.revisions.last?.amount, 4201)
        XCTAssertEqual(bill.revisions.last?.participants.count, 2, "A new bill is shared by every active roommate.")

        // The first due date defaults to today, so this month's bill is due today, not merely due.
        let card = app.otherElements["bill-\(bill.id)"]
        XCTAssertTrue(card.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(card.staticTexts["Due today"].exists)
        try tap(card.buttons["Record payment for Internet"], in: app)
        XCTAssertTrue(app.staticTexts["Record a bill payment."].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-bill-payment"], in: app,
                until: app.staticTexts["Bill payment recorded. Roomlings tracks it; no money moved."])
        let paid = try await billsState(home)
        let payment = try XCTUnwrap(paid.payments.first)
        XCTAssertEqual(paid.payments.count, 1)
        XCTAssertEqual(payment.bill.billId, bill.id)
        XCTAssertEqual(payment.amount, 4201)
        XCTAssertTrue(card.staticTexts["Paid"].waitForExistence(timeout: Wait.control))

        try tap(card.buttons["Undo payment for Internet"], in: app)
        XCTAssertTrue(app.staticTexts["Undo this bill payment record?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-undo-bill-payment"], in: app,
                until: app.staticTexts["Bill payment record removed."])
        let undone = try await billsState(home)
        XCTAssertTrue(undone.payments.isEmpty)
        XCTAssertEqual(undone.bills.count, 1)
        XCTAssertTrue(card.staticTexts["Due today"].waitForExistence(timeout: Wait.control))

        // Pausing stops future months but keeps this month's due bill payable.
        let schedule = app.otherElements["bill-schedule-\(bill.id)"]
        try tap(schedule.buttons["Pause Internet"], in: app)
        XCTAssertTrue(app.staticTexts["Pause this monthly bill?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["confirm-pause-bill"], in: app, until: app.staticTexts["Monthly bill paused."])
        let paused = try await billsState(home)
        XCTAssertNotNil(paused.bills.first?.pauses.first { $0.untilMonth == nil })
        XCTAssertTrue(card.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(card.buttons["Record payment for Internet"].exists)
        try tap(app.buttons["Next bill month"], in: app, until: app.staticTexts["No bills scheduled here."])
        try tap(app.buttons["bills-this-month"], in: app, until: card)

        XCTAssertTrue(paused.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        XCTAssertEqual(paused.requests.count, 4)
    }

    @MainActor
    func testLedgerExportOpensTheShareSheetWithTheReceiptBookFile() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, _) = try await launchMoney()
        try openSection("Bills", in: app)
        let export = app.buttons["export-ledger"]
        try tap(export, in: app)
        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "roomlings-ledger")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: Wait.control), "The share sheet offers the ledger as a named CSV file.")
        let save = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: Wait.control), "The ledger can be saved as a file.")
    }
}
