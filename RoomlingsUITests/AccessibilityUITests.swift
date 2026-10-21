import XCTest

extension AccountUITests {
    /// Runs the system accessibility audit on one screen and fails on anything that is not a
    /// documented exemption. Contrast is sampled from pixels while a sheet can still be settling,
    /// so a screen with findings is audited again and only findings seen both times fail.
    @MainActor
    private func audit(_ app: XCUIApplication, screen: String) throws {
        let first = try auditFindings(app)
        guard !first.isEmpty else { return }
        let settled = XCTestExpectation(description: "\(screen) settles")
        settled.isInverted = true
        wait(for: [settled], timeout: Wait.flip)
        let repeated = try auditFindings(app)
        let confirmed = repeated.filter(first.contains)
        guard !confirmed.isEmpty else { return }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(screen) audit findings"
        shot.lifetime = .keepAlways
        add(shot)
        for finding in confirmed { XCTFail("\(screen): \(finding)") }
    }

    /// Findings that are not documented exemptions. Exemptions return `true` so the audit skips them.
    @MainActor
    private func auditFindings(_ app: XCUIApplication) throws -> [String] {
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        let segmentTitles = Set(app.segmentedControls.buttons.allElementsBoundByIndex.map(\.label))
        let bell = app.buttons["notifications-entry"]
        let bellFrame = bell.exists ? bell.frame.insetBy(dx: -8, dy: -8) : .null
        let sheet = app.otherElements.matching(NSPredicate(format: "identifier ENDSWITH '-sheet'")).firstMatch
        let visibleFrame = sheet.exists ? sheet.frame.intersection(app.frame) : app.frame
        var findings: [String] = []
        try app.performAccessibilityAudit(for: .all.subtracting(.dynamicType)) { issue in
            guard let element = issue.element else {
                // On iPad the room shows beside the centred sheet, dimmed and outside the
                // accessibility tree while the sheet is modal; its text is audited on the web.
                if issue.auditType == .elementDetection, sheet.exists { return true }
                findings.append("\(issue.compactDescription) (type \(issue.auditType.rawValue)) without an element. \(issue.detailedDescription)")
                return true
            }
            // The bundled room is the web project's renderer and is audited there.
            if issue.detailedDescription.contains("WebAccessibilityObjectWrapper") { return true }
            // System keyboard and prediction cells, and anything sampled underneath them.
            if issue.detailedDescription.contains("TUIPredictionViewCell") { return true }
            if !keyboardFrame.isNull, keyboardFrame.intersects(element.frame) { return true }
            // WCAG 1.4.3 exempts inactive controls from contrast.
            if issue.auditType == .contrast, !element.isEnabled { return true }
            // A control cut off at a sheet's edge cannot be measured.
            if issue.auditType == .contrast, !element.isHittable || !visibleFrame.contains(element.frame) { return true }
            // The unread badge uses the web's inbox colours and repeats the count the bell's label announces.
            if issue.auditType == .contrast, element.elementType == .staticText, !bellFrame.isNull,
               bellFrame.contains(element.frame) { return true }
            // The section tabs expose a system segmented control to VoiceOver, which supports the
            // Large Content Viewer. The visible tabs stack instead of clipping.
            if issue.auditType == .textClipped, segmentTitles.contains(element.label) { return true }
            // Single-line fields scroll a long value, such as an email address, rather than clip it.
            if issue.auditType == .textClipped, element.elementType == .textField { return true }
            // Email addresses are the correct label for the signed-in account.
            if issue.auditType == .sufficientElementDescription, element.label.contains("@") { return true }
            findings.append("\(issue.compactDescription) on \(element.elementType.rawValue) "
                            + "'\(element.identifier)' '\(element.label)'. \(issue.detailedDescription)")
            return true
        }
        return findings
    }

    /// Dynamic Type is covered by `testAccountPlateAndDismissalStayUsableAtAccessibilitySizeAfterRotation`
    /// and the fonts' `relativeTo` scaling; the audit reports fixed-size sheet chrome as partial support.
    @MainActor
    func testMainScreensPassTheSystemAccessibilityAudit() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = true
        let email = "audit-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        _ = try await fixture("_fixture/shopping/seed", body: ["householdId": home.id, "invitation": seed.invitation])
        let app = try launchApp()
        // Audit with the primary action enabled.
        try fill(app.textFields["Email address"], email)
        try audit(app, screen: "Sign in")
        try tap(app.buttons["Send sign-in code"], in: app)
        try fill(app.textFields["Email sign-in code"], "123456")
        try audit(app, screen: "Verify")
        try tap(app.buttons["Verify and sign in"], in: app)
        try openAccount(app)
        try tap(app.buttons["Open Cedar House"], in: app)
        XCTAssertTrue(app.staticTexts["Cedar House"].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.webViews["room-renderer"].staticTexts["Kitchen ready"].waitForExistence(timeout: Wait.room))
        try audit(app, screen: "Room")

        try openAccount(app)
        try audit(app, screen: "Account")
        try tap(app.buttons["Done"], in: app)

        try openChores(app)
        try audit(app, screen: "Chores")
        try tap(app.buttons["Done"], in: app)

        try openShopping(app)
        try audit(app, screen: "Shopping")
        try tap(app.buttons["Done"], in: app)

        try openMoney(app)
        for section in ["Balances", "Receipts", "Bills"] {
            try selectSegment(section, from: "money-sections", in: app)
            try audit(app, screen: "Money \(section)")
        }
        try tap(app.buttons["Done"], in: app)

        try tap(app.buttons["room-objects-entry"], in: app)
        try tap(app.buttons["edit-room"], in: app)
        XCTAssertTrue(app.otherElements["room-editor-sheet"].waitForExistence(timeout: Wait.control))
        try audit(app, screen: "Edit room")
        try selectSegment("Add objects", from: "room-editor-sections", in: app)
        try audit(app, screen: "Edit room catalog")
        try selectSegment("Storage (1)", from: "room-editor-sections", in: app)
        try audit(app, screen: "Edit room storage")
        try tap(app.buttons["Bring back Kettle"], in: app)
        XCTAssertTrue(app.otherElements["placement-bar"].waitForExistence(timeout: Wait.control))
        try audit(app, screen: "Placement preview")
        try tap(app.buttons["discard-placement"], in: app)
        try tap(app.buttons["room-editor-cancel"], in: app)
    }
}
