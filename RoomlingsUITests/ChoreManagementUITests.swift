import XCTest

extension AccountUITests {
    @MainActor
    func testChoresEditArchiveRestoreAndKeepSharedHistory() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        _ = try await fixture("_fixture/deletion/receipt", body: ["householdId": home.id])
        try tap(app.buttons["Refresh chores"], in: app)
        let initial = try await choreState(home.id)
        let chore = try XCTUnwrap(initial.items.first { $0.title == "Wipe the fridge shelves" })
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let before = try await choreState(home.id)
        let completed = try XCTUnwrap(before.items.first { $0.id == chore.id })
        XCTAssertFalse(before.history.isEmpty)
        try tap(app.buttons["Edit \(chore.title)"], in: app)
        XCTAssertEqual(app.textFields["Chore name"].value as? String, chore.title)
        XCTAssertEqual(picker("Repeat", in: app).value as? String, "Weekly")
        try fill(app.textFields["Chore name"], "Wipe the fridge doors")
        try choose("Every 2 weeks", from: "Repeat", in: app)
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["Chore saved."].waitForExistence(timeout: Wait.control))
        let editedState = try await choreState(home.id)
        let edited = try XCTUnwrap(editedState.items.first { $0.id == chore.id })
        XCTAssertEqual(edited.title, "Wipe the fridge doors")
        XCTAssertEqual(edited.notes, completed.notes)
        XCTAssertEqual(edited.repeatDays, 14)
        XCTAssertEqual(edited.dueDate, completed.dueDate)
        XCTAssertEqual(edited.rotation, completed.rotation)
        XCTAssertEqual(edited.turn, completed.turn)
        XCTAssertEqual(edited.occurrence, completed.occurrence)
        XCTAssertEqual(edited.version, completed.version + 1)
        XCTAssertEqual(editedState.historyDigest, before.historyDigest)
        XCTAssertEqual(editedState.ledgerDigest, before.ledgerDigest)
        try tap(app.buttons["Archive \(edited.title)"], in: app)
        XCTAssertTrue(app.staticTexts["Archive this chore?"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Cancel"], in: app)
        let cancelled = try await choreState(home.id)
        XCTAssertEqual(cancelled.version, editedState.version)
        try tap(app.buttons["Archive \(edited.title)"], in: app)
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Archive chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        XCTAssertFalse(app.buttons["Cancel"].isEnabled)
        let uncertain = try await choreState(home.id)
        XCTAssertTrue(try XCTUnwrap(uncertain.items.first { $0.id == chore.id }).archived)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore archived. Its history is kept."].waitForExistence(timeout: Wait.control))
        let archived = try await choreState(home.id)
        XCTAssertEqual(archived.version, uncertain.version)
        assertSameChoreRetry(archived)
        XCTAssertFalse(app.otherElements["chore-\(chore.id)"].exists)
        try selectSegment("Archived", from: "chore-sections", in: app)
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Restore chore"], in: app)
        XCTAssertTrue(app.staticTexts["Restore this chore?"].waitForExistence(timeout: Wait.control))
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Restore chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        let restoredBeforeRetry = try await choreState(home.id)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore restored with its saved schedule."].waitForExistence(timeout: Wait.control))
        let restoredState = try await choreState(home.id)
        let restored = try XCTUnwrap(restoredState.items.first { $0.id == chore.id })
        XCTAssertFalse(restored.archived)
        XCTAssertEqual(restored.version, edited.version + 2)
        XCTAssertEqual(restored.dueDate, edited.dueDate)
        XCTAssertEqual(restored.repeatDays, edited.repeatDays)
        XCTAssertEqual(restored.rotation, edited.rotation)
        XCTAssertEqual(restored.turn, edited.turn)
        XCTAssertEqual(restored.occurrence, edited.occurrence)
        XCTAssertEqual(restoredState.version, restoredBeforeRetry.version)
        XCTAssertEqual(restoredState.historyDigest, before.historyDigest)
        XCTAssertEqual(restoredState.ledgerDigest, before.ledgerDigest)
        assertSameChoreRetry(restoredState)
        try selectSegment("Chores", from: "chore-sections", in: app)
        let stored = try XCTUnwrap(initial.items.first { $0.title == "Clean the stored kettle" })
        XCTAssertFalse(app.buttons["Edit \(stored.title)"].isEnabled)
        try tap(app.buttons["Archive \(stored.title)"], in: app)
        try tap(app.buttons["Archive chore"], in: app)
        XCTAssertTrue(app.staticTexts["Chore archived. Its history is kept."].waitForExistence(timeout: Wait.control))
        try selectSegment("Archived", from: "chore-sections", in: app)
        XCTAssertFalse(app.otherElements["chore-\(stored.id)"].buttons["Restore chore"].isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        try openChores(app)
        XCTAssertTrue(app.staticTexts["Wipe the fridge doors"].waitForExistence(timeout: Wait.control))
        try selectSegment("History", from: "chore-sections", in: app)
        XCTAssertTrue(app.staticTexts["Wipe the fridge shelves"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    func testChoreEditsPreserveDraftsAndRequireConflictReview() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        let initial = try await choreState(home.id)
        let chore = try XCTUnwrap(initial.items.first { $0.title == "Wipe the fridge shelves" })
        try tap(app.buttons["Edit \(chore.title)"], in: app)
        try fill(app.textFields["Chore name"], "My first draft")
        _ = try await fixture("_fixture/chores/change", body: [
            "householdId": home.id, "choreId": chore.id, "title": "Changed on another device"
        ])
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["Save chore"].isEnabled)
        XCTAssertFalse(app.staticTexts["Chore saved."].exists)
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "My first draft")
        try tap(app.buttons["Review latest chores"], in: app)
        XCTAssertTrue(app.buttons["Use latest chore"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "My first draft")
        XCTAssertFalse(app.buttons["Save chore"].isEnabled)
        try tap(app.buttons["Use latest chore"], in: app)
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "Changed on another device")
        try fill(app.textFields["Chore name"], "My reviewed draft")
        _ = try await fixture("_fixture/chores/change", body: [
            "householdId": home.id, "choreId": chore.id, "title": "A newer shared title"
        ])
        let latest = try await choreState(home.id)
        let latestChore = try XCTUnwrap(latest.items.first { $0.id == chore.id })
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Review latest chores"], in: app)
        XCTAssertTrue(app.buttons["Keep my draft"].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Keep my draft"], in: app)
        XCTAssertEqual(app.textFields["Chore name"].value as? String, "My reviewed draft")
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["Chore saved."].waitForExistence(timeout: Wait.control))
        let saved = try await choreState(home.id)
        XCTAssertEqual(saved.items.first { $0.id == chore.id }?.title, "My reviewed draft")
        XCTAssertEqual(saved.version, latest.version + 1)
        XCTAssertEqual(saved.items.first { $0.id == chore.id }?.version, latestChore.version + 1)
        XCTAssertEqual(saved.requests.last?.choreVersion, latestChore.version)
        XCTAssertEqual(saved.requests.last?.version, latest.version)
        XCTAssertEqual(saved.historyDigest, initial.historyDigest)
        XCTAssertEqual(saved.ledgerDigest, initial.ledgerDigest)
        XCTAssertTrue(saved.requests.allSatisfy { $0.method == "PATCH" && $0.native && !$0.browserHeaders })
    }

    @MainActor
    func testChoreEditsRetryAndScheduleCompletedOneOffsWithoutChangingHistory() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        let initial = try await choreState(home.id)
        let chore = try XCTUnwrap(initial.items.first { $0.title == "Wipe the fridge shelves" })
        try tap(app.buttons["Edit \(chore.title)"], in: app)
        try choose("One-off", from: "Repeat", in: app)
        _ = try await fixture("_fixture/chores/failure", body: ["mode": "lost-response"])
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["chores-error"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Chore saved."].exists)
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        XCTAssertFalse(app.buttons["Cancel"].isEnabled)
        XCTAssertFalse(picker("Repeat", in: app).isEnabled)
        let uncertain = try await choreState(home.id)
        XCTAssertNil(uncertain.items.first { $0.id == chore.id }?.repeatDays)
        try tap(app.buttons["Retry save"], in: app)
        XCTAssertTrue(app.staticTexts["Chore saved."].waitForExistence(timeout: Wait.control))
        let confirmed = try await choreState(home.id)
        XCTAssertEqual(confirmed.version, uncertain.version)
        assertSameChoreRetry(confirmed)
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        let completedState = try await choreState(home.id)
        let completed = try XCTUnwrap(completedState.items.first { $0.id == chore.id })
        let completion = try XCTUnwrap(completedState.history.first { $0.choreId == chore.id })
        XCTAssertNil(completed.dueDate)
        try selectSegment("History", from: "chore-sections", in: app)
        try tap(app.otherElements["completion-\(completion.id)"].buttons["Schedule again"], in: app)
        XCTAssertTrue(app.staticTexts["Schedule this chore again."].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.textFields["Chore name"].value as? String, chore.title)
        XCTAssertEqual(picker("Repeat", in: app).value as? String, "One-off")
        try tap(app.buttons["Save chore"], in: app)
        XCTAssertTrue(app.staticTexts["Chore saved."].waitForExistence(timeout: Wait.control))
        let scheduledState = try await choreState(home.id)
        let scheduled = try XCTUnwrap(scheduledState.items.first { $0.id == chore.id })
        XCTAssertEqual(scheduled.dueDate, scheduledState.today)
        XCTAssertEqual(scheduled.occurrence, completed.occurrence)
        XCTAssertEqual(scheduled.version, completed.version + 1)
        XCTAssertEqual(scheduledState.historyDigest, completedState.historyDigest)
        XCTAssertEqual(scheduledState.ledgerDigest, initial.ledgerDigest)
        XCTAssertTrue(app.otherElements["chore-\(chore.id)"].buttons["Mark done"].isEnabled)
        try selectSegment("History", from: "chore-sections", in: app)
        XCTAssertFalse(app.otherElements["completion-\(completion.id)"].buttons["Schedule again"].exists)
        XCTAssertFalse(app.otherElements["completion-\(completion.id)"].buttons["Undo completion"].exists)
    }

    @MainActor
    private func assertSameChoreRetry(_ state: ChoreState) {
        let attempts = Array(state.requests.suffix(2))
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotNil(attempts.first?.mutationId)
        XCTAssertEqual(attempts.first?.mutationId, attempts.last?.mutationId)
        XCTAssertEqual(attempts.first?.choreVersion, attempts.last?.choreVersion)
        XCTAssertEqual(attempts.first?.version, attempts.last?.version)
        XCTAssertEqual(attempts.first?.mutationVersion, attempts.last?.mutationVersion)
        XCTAssertEqual(attempts.first?.path, attempts.last?.path)
        XCTAssertEqual(attempts.first?.method, "PATCH")
        XCTAssertEqual(attempts.last?.method, "PATCH")
    }

    @MainActor
    func testRoomsSwitchFromTheHeaderAndOpenThatRoomsChores() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let email = "rooms-\(UUID().uuidString.lowercased())@example.test"
        _ = try await fixture("_fixture/seed", body: ["email": email])
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        let room = app.webViews["room-renderer"]
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        let rooms = app.buttons["room-entry"]
        XCTAssertTrue(rooms.waitForExistence(timeout: Wait.control))
        XCTAssertEqual(rooms.value as? String, "Kitchen")

        for (name, roomID) in [("Bathroom", "bathroom"), ("Living room", "living-room")] {
            try tap(rooms, in: app, until: app.buttons[name])
            try tap(app.buttons[name], in: app)
            XCTAssertTrue(room.staticTexts["\(name) ready"].waitForExistence(timeout: Wait.room))
            XCTAssertEqual(rooms.value as? String, name)
            let chores = room.descendants(matching: .any).matching(identifier: "Chores").firstMatch
            let sheet = app.otherElements["chores-sheet"]
            try tap(chores, in: app, until: sheet)
            XCTAssertEqual(picker("Chore room", in: app).value as? String, name,
                           "Chores opened from the \(roomID) start on that room.")
            try tap(app.buttons["Done"], in: app)
            XCTAssertTrue(room.staticTexts["\(name) ready"].waitForExistence(timeout: Wait.room))
        }

        try tap(rooms, in: app, until: app.buttons["Kitchen"])
        try tap(app.buttons["Kitchen"], in: app)
        XCTAssertTrue(room.staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
    }

    @MainActor
    func testOverdueChoresDirtyTheirObjectUntilCompleted() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (app, home) = try await launchChores()
        let initial = try await choreState(home.id)
        let chore = try XCTUnwrap(initial.items.first { $0.title == "Wipe the fridge shelves" })
        _ = try await fixture("_fixture/chores/change", body: [
            "householdId": home.id, "choreId": chore.id, "overdueDays": 8,
        ])
        try tap(app.buttons["Refresh chores"], in: app)
        try tap(app.buttons["Done"], in: app)
        let room = app.webViews["room-renderer"]
        let dirty = room.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", dirty: 8 days overdue")).firstMatch
        XCTAssertTrue(dirty.waitForExistence(timeout: Wait.room), "The fridge shows its overdue chore as dirt.")

        try openChores(app)
        try tap(app.otherElements["chore-\(chore.id)"].buttons["Mark done"], in: app)
        try tap(app.buttons["Record completion"], in: app)
        XCTAssertTrue(app.staticTexts["Chore completed."].waitForExistence(timeout: Wait.control))
        try tap(app.buttons["Done"], in: app)
        let clean = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: clean, object: dirty)], timeout: Wait.room),
                       .completed, "Completing the chore cleans the fridge at once.")
    }

    @MainActor
    func testNotificationsListYourTurnsAndKeepReadStateOnTheServer() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let email = "inbox-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        let app = try launchApp()
        try signIn(app, email: email)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        let bell = app.buttons["notifications-entry"]
        // The stored kettle's chore is paused, so only the fridge turn is waiting.
        XCTAssertTrue(bell.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(waitForLabel(bell, "Notifications, 1 unread"))
        attachScreenshot("Notifications bell")

        try tap(bell, in: app, until: app.otherElements["notifications-sheet"])
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wipe the fridge shelves is due today")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: Wait.control))
        XCTAssertEqual(item.value as? String, "Unread")
        attachScreenshot("Notifications sheet")
        try tap(item, in: app, until: app.otherElements["chores-sheet"])
        XCTAssertEqual(picker("Chore room", in: app).value as? String, "Kitchen")
        XCTAssertTrue(try switchIsOn(app.switches["My turn only"]), "Your turns open with My turn only, as on the web.")
        try tap(app.buttons["Done"], in: app)
        XCTAssertTrue(waitForLabel(bell, "Notifications"))

        // Read state belongs to the account on the server, so it survives a relaunch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(bell.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(waitForLabel(bell, "Notifications"))

        // An overdue turn is a new notification; Mark all read clears it.
        let state = try await choreState(home.id)
        let chore = try XCTUnwrap(state.items.first { $0.title == "Wipe the fridge shelves" })
        _ = try await fixture("_fixture/chores/change", body: ["householdId": home.id, "choreId": chore.id, "overdueDays": 2])
        app.terminate()
        app.launch()
        XCTAssertTrue(bell.waitForExistence(timeout: Wait.control))
        XCTAssertTrue(waitForLabel(bell, "Notifications, 1 unread"))
        try tap(bell, in: app, until: app.otherElements["notifications-sheet"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wipe the fridge shelves is 2 days overdue"))
            .firstMatch.waitForExistence(timeout: Wait.control))
        try tap(app.buttons["inbox-read-all"], in: app)
        XCTAssertFalse(app.buttons["inbox-read-all"].isEnabled)
        try tap(app.buttons["Done"], in: app)
        XCTAssertTrue(waitForLabel(bell, "Notifications"))
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: Wait.control) == .completed
    }
}
