import XCTest

extension AccountUITests {
    private struct ShoppingState: Decodable {
        struct Item: Decodable, Equatable {
            let id: String
            let name: String
            let quantity: String
            let notes: String
            let version: Int
            let claimedBy: String?
            let pickedUp: Bool
        }
        struct Request: Decodable {
            let method: String
            let version: Int
            let itemVersion: Int?
            let mutationId: String?
            let mutationVersion: Int?
            let native: Bool
            let browserHeaders: Bool
        }
        let version: Int
        let items: [Item]
        let requests: [Request]
        let ledger: String
    }

    private struct RemoteShopping: Decodable {
        let items: [ShoppingState.Item]
    }

    @MainActor
    private func openShopping(_ app: XCUIApplication) throws {
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        let button = room.descendants(matching: .any).matching(identifier: "Shopping").firstMatch
        let sheet = app.otherElements["shopping-sheet"]
        for _ in 0..<3 {
            try tap(button, in: app)
            if sheet.waitForExistence(timeout: Wait.flip) {
                if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertLessThan(sheet.frame.width, app.frame.width) }
                return
            }
        }
        XCTFail("The Shopping dock button did not open its native sheet.")
    }

    @MainActor
    private func launchShopping() async throws -> (XCUIApplication, Seed.Home) {
        let email = "shopping-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        _ = try await fixture("_fixture/shopping/seed", body: ["householdId": home.id, "invitation": seed.invitation])
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openShopping(app)
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.staticTexts["For Kitchen: Fridge"].exists)
        return (app, home)
    }

    @MainActor
    private func shoppingState(_ home: Seed.Home) async throws -> ShoppingState {
        try JSONDecoder().decode(ShoppingState.self, from: await fixture("_fixture/shopping/state", body: ["householdId": home.id]))
    }

    @MainActor
    private func remoteShopping(_ home: Seed.Home) async throws -> RemoteShopping {
        try JSONDecoder().decode(RemoteShopping.self, from: await fixture("_fixture/shopping/remote", body: [
            "householdId": home.id, "action": "read",
        ]))
    }

    @MainActor
    private func dismissSheet(_ identifier: String, in app: XCUIApplication) throws {
        let sheet = app.otherElements[identifier]
        XCTAssertTrue(sheet.exists)
        XCTAssertFalse(app.buttons["Back"].exists)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let grabber = app.buttons["Sheet Grabber"]
            XCTAssertTrue(grabber.waitForExistence(timeout: Wait.control))
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        } else {
            try tap(app.buttons["Done"], in: app)
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: Wait.control), .completed)
    }

    @MainActor
    func testSheetsLoadWithTheSharedLogoAndDismissWithoutBackButtons() async throws {
        executionTimeAllowance = 300
        continueAfterFailure = false
        let (app, home) = try await launchShopping()
        try dismissSheet("shopping-sheet", in: app)
        let loader = app.descendants(matching: .any).matching(identifier: "sheet-loading").firstMatch

        _ = try await fixture("_fixture/loading", body: ["hold": true])
        try openShopping(app)
        XCTAssertTrue(loader.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Milk"].exists)
        XCTAssertFalse(app.buttons["Add item"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Shared logo before shopping loads"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        _ = try await fixture("_fixture/shopping/remote", body: ["householdId": home.id, "action": "add"])
        _ = try await fixture("_fixture/loading", body: ["hold": false])
        XCTAssertTrue(app.staticTexts["Bread"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(loader.exists)

        _ = try await fixture("_fixture/loading", body: ["hold": true, "fail": true])
        try tap(app.buttons["Refresh shopping"], in: app)
        XCTAssertTrue(loader.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Bread"].exists)
        _ = try await fixture("_fixture/loading", body: ["hold": false])
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(loader.exists)
        try tap(app.buttons["Refresh shopping"], in: app)
        XCTAssertTrue(app.buttons["Add item"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Add item"], in: app)
        XCTAssertTrue(app.textFields["Item name"].waitForExistence(timeout: Wait.control))
        try dismissSheet("shopping-sheet", in: app)

        _ = try await fixture("_fixture/loading", body: ["hold": true])
        try openChores(app)
        XCTAssertTrue(loader.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Wipe the fridge shelves"].exists)
        _ = try await fixture("_fixture/loading", body: ["hold": false])
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Add chore"], in: app)
        XCTAssertTrue(app.textFields["Chore name"].waitForExistence(timeout: Wait.control))
        try dismissSheet("chores-sheet", in: app)

        _ = try await fixture("_fixture/loading", body: ["hold": true])
        try openAccount(app)
        XCTAssertTrue(loader.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Create a household"].exists)
        _ = try await fixture("_fixture/loading", body: ["hold": false])
        try tap(app.buttons["Create a household"], in: app)
        XCTAssertTrue(app.textFields["Household name"].waitForExistence(timeout: Wait.control))
        try dismissSheet("account-sheet", in: app)
        try openShopping(app)
        XCTAssertTrue(app.buttons["Add item"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Back"].exists)
    }

    @MainActor
    func testShoppingEditsClaimsAndPicksWithoutCreatingDebt() async throws {
        executionTimeAllowance = 300
        continueAfterFailure = false
        let (app, home) = try await launchShopping()
        let initial = try await shoppingState(home)
        XCTAssertFalse(app.buttons["Finish shopping"].exists)
        XCTAssertFalse(app.buttons["Record without a list"].exists)
        XCTAssertFalse(app.buttons["Past runs"].exists)
        try tap(app.buttons["Add item"], in: app)
        try fill(app.textFields["Item name"], "Apples")
        try fill(app.textFields["Quantity"], "4")
        try tap(app.buttons["Add to shopping list"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item added."].waitForExistence(timeout: Wait.control))
        let added = try await shoppingState(home)
        let item = try XCTUnwrap(added.items.first { $0.name == "Apples" })
        let card = app.otherElements["shopping-\(item.id)"]
        try tap(card.buttons["Edit Apples"], in: app)
        try fill(app.textFields["Quantity"], "5")
        try tap(app.buttons["Save item"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item updated."].waitForExistence(timeout: Wait.control))
        try tap(card.buttons["Claim Apples"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item claimed."].waitForExistence(timeout: Wait.control))
        try setSwitch(card.switches["Picked up Apples"], on: true, in: app)
        XCTAssertTrue(app.staticTexts["Item picked up. No expense was created."].waitForExistence(timeout: Wait.control))
        try tap(app.segmentedControls["shopping-sections"].buttons["Basket"], in: app)
        XCTAssertTrue(card.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Milk"].exists)
        XCTAssertFalse(card.buttons["Edit Apples"].isEnabled)
        XCTAssertFalse(card.buttons["Remove Apples"].isEnabled)
        let picked = try await shoppingState(home)
        XCTAssertEqual(picked.items.first { $0.id == item.id }?.quantity, "5")
        XCTAssertEqual(picked.items.first { $0.id == item.id }?.pickedUp, true)
        XCTAssertEqual(picked.ledger, initial.ledger)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Native shopping basket"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try tap(card.switches["Picked up Apples"], in: app)
        XCTAssertTrue(app.staticTexts["Your basket is empty."].waitForExistence(timeout: Wait.control))
        try tap(app.segmentedControls["shopping-sections"].buttons["List"], in: app)
        try tap(card.buttons["Release claim on Apples"], in: app)
        try tap(app.buttons["Release claim"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping claim released."].waitForExistence(timeout: Wait.control))
        try tap(card.buttons["Remove Apples"], in: app)
        try tap(app.buttons["Remove item"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item removed."].waitForExistence(timeout: Wait.control))
        let removed = try await shoppingState(home)
        XCTAssertFalse(removed.items.contains { $0.id == item.id })
        XCTAssertEqual(removed.ledger, initial.ledger)
        XCTAssertEqual(Set(removed.requests.map(\.method)), ["POST", "PATCH", "DELETE"])
        XCTAssertTrue(removed.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openShopping(app)
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Apples"].exists)
    }

    @MainActor
    func testShoppingRefreshesAnotherMembersChangesAndReviewsConflicts() async throws {
        executionTimeAllowance = 300
        continueAfterFailure = false
        let (app, home) = try await launchShopping()
        let initial = try await shoppingState(home)
        let milk = try XCTUnwrap(initial.items.first { $0.name == "Milk" })
        let oats = try XCTUnwrap(initial.items.first { $0.name == "Oats" })
        let otherCard = app.otherElements["shopping-\(oats.id)"]
        XCTAssertFalse(otherCard.switches["Picked up Oats"].isEnabled)
        XCTAssertFalse(otherCard.buttons["Edit Oats"].isEnabled)
        XCTAssertFalse(otherCard.buttons["Remove Oats"].isEnabled)
        _ = try await fixture("_fixture/shopping/remote", body: ["householdId": home.id, "action": "add"])
        XCTAssertFalse(app.staticTexts["Bread"].exists)
        try tap(app.buttons["Refresh shopping"], in: app)
        XCTAssertTrue(app.staticTexts["Bread"].waitForExistence(timeout: Wait.control))
        let card = app.otherElements["shopping-\(milk.id)"]
        try tap(card.buttons["Edit Milk"], in: app)
        XCTAssertTrue(app.staticTexts["For Kitchen: Fridge"].exists)
        try fill(app.textFields["Quantity"], "6 cartons")
        _ = try await fixture("_fixture/shopping/remote", body: ["householdId": home.id, "itemId": milk.id, "action": "edit"])
        try tap(app.buttons["Save item"], in: app)
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Save item"].isEnabled)
        XCTAssertEqual(app.textFields["Quantity"].value as? String, "6 cartons")
        let conflicted = try await shoppingState(home)
        XCTAssertEqual(conflicted.items.first { $0.id == milk.id }?.quantity, "3 cartons")
        try tap(app.buttons["Review latest shopping"], in: app)
        XCTAssertTrue(app.buttons["Keep my draft"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Keep my draft"], in: app)
        XCTAssertEqual(app.textFields["Quantity"].value as? String, "6 cartons")
        try tap(app.buttons["Save item"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item updated."].waitForExistence(timeout: Wait.control))
        let otherDevice = try await remoteShopping(home)
        XCTAssertEqual(otherDevice.items.first { $0.id == milk.id }?.quantity, "6 cartons")
        _ = try await fixture("_fixture/shopping/remote", body: ["householdId": home.id, "itemId": milk.id, "action": "claim"])
        try tap(card.buttons["Claim Milk"], in: app)
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Review latest shopping"], in: app)
        XCTAssertFalse(card.switches["Picked up Milk"].isEnabled)
        XCTAssertTrue(card.staticTexts["Sam is buying this"].exists)
        try tap(card.buttons["Release claim on Milk"], in: app)
        XCTAssertTrue(app.staticTexts["Release this shopping claim?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Release claim"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping claim released."].waitForExistence(timeout: Wait.control))
        let released = try await remoteShopping(home)
        XCTAssertNil(released.items.first { $0.id == milk.id }?.claimedBy)
        let latest = try await shoppingState(home)
        XCTAssertEqual(latest.ledger, initial.ledger)
    }

    @MainActor
    func testShoppingKeepsFailedDraftsAndReplaysLostSavesOnce() async throws {
        executionTimeAllowance = 300
        continueAfterFailure = false
        let (app, home) = try await launchShopping()
        let initial = try await shoppingState(home)
        try tap(app.buttons["Add item"], in: app)
        try fill(app.textFields["Item name"], "Rice")
        _ = try await fixture("_fixture/shopping/failure", body: ["mode": "unavailable"])
        try tap(app.buttons["Add to shopping list"], in: app)
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Item name"].value as? String, "Rice")
        XCTAssertFalse(app.buttons["Add to shopping list"].isEnabled)
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        XCTAssertFalse(app.staticTexts["Shopping item added."].exists)
        let failed = try await shoppingState(home)
        XCTAssertFalse(failed.items.contains { $0.name == "Rice" })
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item added."].waitForExistence(timeout: Wait.control))
        let added = try await shoppingState(home)
        let item = try XCTUnwrap(added.items.first { $0.name == "Rice" })
        let card = app.otherElements["shopping-\(item.id)"]
        try tap(card.buttons["Edit Rice"], in: app)
        try fill(app.textFields["Quantity"], "2 bags")
        _ = try await fixture("_fixture/shopping/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Save item"], in: app)
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Shopping item updated."].exists)
        let unconfirmed = try await shoppingState(home)
        XCTAssertEqual(unconfirmed.items.first { $0.id == item.id }?.quantity, "2 bags")
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item updated."].waitForExistence(timeout: Wait.control))
        let edited = try await shoppingState(home)
        XCTAssertEqual(edited.version, unconfirmed.version)
        XCTAssertEqual(edited.items.filter { $0.id == item.id }.count, 1)
        assertShoppingReplay(edited.requests)
        try tap(card.buttons["Remove Rice"], in: app)
        _ = try await fixture("_fixture/shopping/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Remove item"], in: app)
        XCTAssertTrue(app.staticTexts["shopping-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Shopping item removed."].exists)
        let unconfirmedRemoval = try await shoppingState(home)
        XCTAssertFalse(unconfirmedRemoval.items.contains { $0.id == item.id })
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Shopping item removed."].waitForExistence(timeout: Wait.control))
        let removed = try await shoppingState(home)
        XCTAssertEqual(removed.version, unconfirmedRemoval.version)
        XCTAssertEqual(removed.ledger, initial.ledger)
        assertShoppingReplay(removed.requests)
    }

    private func assertShoppingReplay(_ requests: [ShoppingState.Request]) {
        let attempts = Array(requests.suffix(2))
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotNil(attempts.first?.mutationId)
        XCTAssertEqual(attempts.first?.mutationId, attempts.last?.mutationId)
        XCTAssertEqual(attempts.first?.version, attempts.last?.version)
        XCTAssertEqual(attempts.first?.mutationVersion, attempts.last?.mutationVersion)
        XCTAssertEqual(attempts.first?.itemVersion, attempts.last?.itemVersion)
        XCTAssertEqual(attempts.first?.method, attempts.last?.method)
    }

    @MainActor
    func testBasketCheckoutRecordsOneReceiptAndClearsThoseItems() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchShopping()
        let opening = try await ledgerState(home)
        XCTAssertTrue(opening.expenses.isEmpty)
        XCTAssertTrue(opening.runs.isEmpty)
        // Oats is already claimed by the fixture roommate, so the basket has to start from Milk.
        let basketItem = try XCTUnwrap(opening.items.first { $0.name == "Milk" })
        try setSwitch(app.otherElements["shopping-\(basketItem.id)"].switches["Picked up Milk"], on: true, in: app)
        XCTAssertTrue(app.staticTexts["Item picked up. No expense was created."].waitForExistence(timeout: Wait.control))
        let ticked = try await ledgerState(home)
        XCTAssertTrue(ticked.expenses.isEmpty, "Ticking an item must never create a debt.")
        try tap(app.segmentedControls["shopping-sections"].buttons["Basket"], in: app)
        try tap(app.buttons["record-basket-receipt"], in: app)
        XCTAssertTrue(app.staticTexts["1 item from your basket"].waitForExistence(timeout: Wait.control))
        try fill(app.textFields["Amount"], "4.50")
        try submitReceipt(app, expecting: "Receipt recorded and the basket cleared.", sheet: "shopping")
        let checkedOut = try await ledgerState(home)
        let run = try XCTUnwrap(checkedOut.runs.first { $0.items.contains { $0.id == basketItem.id } })
        let receipt = try XCTUnwrap(checkedOut.expenses.first { $0.id == run.expenseId })
        XCTAssertEqual(receipt.amount, 450)
        XCTAssertEqual(receipt.shoppingRunId, run.id)
        XCTAssertFalse(checkedOut.items.contains { $0.id == basketItem.id })
        XCTAssertEqual(checkedOut.balances.values.reduce(0, +), 0)
        XCTAssertTrue(checkedOut.requests.allSatisfy { $0.native && !$0.browserHeaders && $0.mutationId != nil })
        XCTAssertFalse(app.staticTexts["1 item from your basket"].exists)
    }
}
