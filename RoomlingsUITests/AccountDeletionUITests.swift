import XCTest

extension AccountUITests {
    private struct DeletionState: Decodable {
        struct Home: Decodable {
            struct Member: Decodable { let id: String; let name: String; let inactive: Bool? }
            let id: String
            let members: [Member]
            let expenses: Int
            let ledgerDigest: String
        }
        struct Request: Decodable { let method: String; let native: Bool; let browserHeaders: Bool }
        let accountExists: Bool
        let pending: Bool
        let households: [Home]
        let requests: [Request]
        let deletionAttempts: Int
        let verificationRequests: Int
    }

    @MainActor
    private func deletionState(_ email: String, _ seed: Seed) async throws -> DeletionState {
        try JSONDecoder().decode(DeletionState.self, from: await fixture(
            "_fixture/deletion/state", body: ["email": email, "householdIds": seed.homes.map(\.id)]
        ))
    }

    @MainActor
    private func deletionSeed() async throws -> (String, Seed) {
        let email = "deletion-\(UUID().uuidString.lowercased())@example.test"
        let seed = try JSONDecoder().decode(Seed.self, from: await fixture("_fixture/seed", body: ["email": email]))
        return (email, seed)
    }

    @MainActor
    private func openDeletion(_ app: XCUIApplication, alreadyInAccount: Bool = false) throws {
        if !alreadyInAccount { try openAccount(app) }
        try tap(app.buttons["open-account-deletion"], in: app)
        XCTAssertTrue(app.textFields["Account email to confirm deletion"].waitForExistence(timeout: Wait.control))
    }

    @MainActor
    private func confirmDeletion(_ app: XCUIApplication, email: String) throws {
        try fill(app.textFields["Account email to confirm deletion"], email)
        try tap(app.buttons["confirm-account-deletion"], in: app)
    }

    @MainActor
    func testAccountDeletionRequiresExactConfirmationAndKeepsTheSharedLedger() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (email, seed) = try await deletionSeed()
        let home = try XCTUnwrap(seed.homes.first)
        _ = try await fixture("_fixture/deletion/receipt", body: ["householdId": home.id])
        let before = try await deletionState(email, seed)
        XCTAssertEqual(before.households.first?.expenses, 1)
        let app = try launchApp()
        try signIn(app, email: email)
        try openDeletion(app)
        try fill(app.textFields["Account email to confirm deletion"], email.uppercased())
        XCTAssertFalse(app.buttons["confirm-account-deletion"].isEnabled)
        try tap(app.buttons["Cancel"], in: app)
        let cancelled = try await deletionState(email, seed)
        XCTAssertTrue(cancelled.accountExists)
        XCTAssertTrue(cancelled.requests.isEmpty)
        try openDeletion(app, alreadyInAccount: true)
        attachHeaderScreenshot("Native account deletion confirmation")
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.staticTexts["Account deleted. Shared ledger history kept."].waitForExistence(timeout: Wait.control))
        let after = try await deletionState(email, seed)
        XCTAssertFalse(after.accountExists)
        XCTAssertFalse(after.pending)
        XCTAssertEqual(after.deletionAttempts, 1)
        XCTAssertEqual(after.requests.count, 1)
        XCTAssertTrue(after.requests.allSatisfy { $0.method == "DELETE" && $0.native && !$0.browserHeaders })
        XCTAssertEqual(after.households.map(\.ledgerDigest), before.households.map(\.ledgerDigest))
        XCTAssertTrue(after.households.allSatisfy { $0.members.allSatisfy { $0.inactive == true && $0.name.hasPrefix("Former roommate") } })
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: Wait.control))
        XCTAssertEqual(app.buttons["household-entry"].label, "Kitchen preview")
    }

    @MainActor
    func testAccountDeletionReauthenticatesWithoutDeletingUntilConfirmedAgain() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (email, seed) = try await deletionSeed()
        let app = try launchApp()
        try signIn(app, email: email)
        _ = try await fixture("_fixture/deletion/age-session", body: ["email": email])
        try openDeletion(app)
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.staticTexts["Verify your email again before deleting your account."].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["confirm-account-deletion"].isEnabled)
        try tap(app.buttons["reauthenticate-account"], in: app)
        XCTAssertFalse(app.textFields["Email address"].exists)
        try tap(app.buttons["send-deletion-verification"], in: app)
        XCTAssertTrue(app.staticTexts["Check your email for a sign-in code."].waitForExistence(timeout: Wait.control))
        try fill(app.textFields["Email sign-in code"], "123456")
        let beforeVerification = try await deletionState(email, seed)
        let verify = app.buttons["verify-deletion-email"]
        let confirmation = app.textFields["Account email to confirm deletion"]
        try tap(verify, in: app)
        if !confirmation.waitForExistence(timeout: Wait.flip) {
            let observed = try await deletionState(email, seed)
            let error = app.staticTexts["account-error"]
            // A fitted iPad sheet can move while dismissing the keyboard. Only repeat a
            // missed tap when the fixture proves that verification was never submitted.
            guard observed.verificationRequests == beforeVerification.verificationRequests,
                  verify.exists, verify.isEnabled, !error.exists else {
                XCTFail("Verification did not return to confirmation: \(error.exists ? error.label : "a request was already submitted").")
                return
            }
            try tap(verify, in: app)
        }
        XCTAssertTrue(confirmation.waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["confirm-account-deletion"].isEnabled)
        let verified = try await deletionState(email, seed)
        XCTAssertTrue(verified.accountExists)
        XCTAssertEqual(verified.deletionAttempts, 0)
        XCTAssertEqual(verified.requests.count, 1)
        XCTAssertEqual(verified.verificationRequests, beforeVerification.verificationRequests + 1)
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.staticTexts["Account deleted. Shared ledger history kept."].waitForExistence(timeout: Wait.control))
        let deleted = try await deletionState(email, seed)
        XCTAssertFalse(deleted.accountExists)
        XCTAssertEqual(deleted.deletionAttempts, 1)
    }

    @MainActor
    func testAccountDeletionWorksWithoutAHouseholdAndClearsTheTypedIdentity() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (_, seed) = try await deletionSeed()
        let email = "empty-account-\(UUID().uuidString.lowercased())@example.test"
        let app = try launchApp()
        try signIn(app, email: email)
        try openDeletion(app, alreadyInAccount: true)
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.staticTexts["Account deleted. Shared ledger history kept."].waitForExistence(timeout: Wait.control))
        let field = app.textFields["Email address"]
        XCTAssertTrue(field.waitForExistence(timeout: Wait.control))
        XCTAssertTrue((field.value as? String ?? "").isEmpty)
        let deleted = try await deletionState(email, seed)
        XCTAssertFalse(deleted.accountExists)
        XCTAssertEqual(deleted.deletionAttempts, 1)
        XCTAssertTrue(deleted.households.allSatisfy { $0.members.allSatisfy { $0.inactive != true } })
    }

    @MainActor
    func testAccountDeletionPendingSurvivesRelaunchAndOffersANativeRetry() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (email, seed) = try await deletionSeed()
        let app = try launchApp()
        try signIn(app, email: email)
        _ = try await fixture("_fixture/deletion/failure", body: ["mode": "provider"])
        try openDeletion(app)
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.buttons["retry-account-deletion"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Account deleted. Shared ledger history kept."].exists)
        let pending = try await deletionState(email, seed)
        XCTAssertTrue(pending.accountExists)
        XCTAssertTrue(pending.pending)
        XCTAssertEqual(pending.deletionAttempts, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["retry-account-deletion"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.buttons["open-account-deletion"].exists)
        XCTAssertEqual(app.buttons["household-entry"].label, "Kitchen preview")
        attachHeaderScreenshot("Native pending account deletion")
        _ = try await fixture("_fixture/deletion/age-session", body: ["email": email])
        _ = try await fixture("_fixture/deletion/failure", body: ["mode": "none"])
        try tap(app.buttons["retry-account-deletion"], in: app)
        XCTAssertTrue(app.staticTexts["Account deleted. Shared ledger history kept."].waitForExistence(timeout: Wait.control))
        let deleted = try await deletionState(email, seed)
        XCTAssertFalse(deleted.accountExists)
        XCTAssertEqual(deleted.deletionAttempts, 2)
    }

    @MainActor
    func testAccountDeletionLostResponseRequiresCheckingStatusWithoutClaimingSuccess() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (email, seed) = try await deletionSeed()
        let app = try launchApp()
        try signIn(app, email: email)
        _ = try await fixture("_fixture/deletion/failure", body: ["mode": "lost-response"])
        try openDeletion(app)
        try confirmDeletion(app, email: email)
        XCTAssertTrue(app.buttons["check-account-deletion"].waitForExistence(timeout: Wait.control))
        XCTAssertFalse(app.staticTexts["Account deleted. Shared ledger history kept."].exists)
        let uncertain = try await deletionState(email, seed)
        XCTAssertFalse(uncertain.accountExists)
        XCTAssertEqual(uncertain.deletionAttempts, 1)
        try tap(app.buttons["check-account-deletion"], in: app)
        XCTAssertTrue(app.staticTexts["Account access has ended. Pending deletions continue on the server."].waitForExistence(timeout: Wait.control))
        XCTAssertTrue(app.textFields["Email address"].exists)
        let checked = try await deletionState(email, seed)
        XCTAssertEqual(checked.requests.count, uncertain.requests.count)
        XCTAssertEqual(checked.deletionAttempts, 1)
    }

    @MainActor
    func testAccountDeletionCannotRemoveAnOwnerWhileOtherRoommatesRemain() async throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let (email, seed) = try await deletionSeed()
        let home = try XCTUnwrap(seed.homes.first { $0.name == "Cedar House" })
        _ = try await fixture("_fixture/shopping/seed", body: ["householdId": home.id, "invitation": seed.invitation])
        let before = try await deletionState(email, seed)
        let app = try launchApp()
        try signIn(app, email: email)
        try openDeletion(app)
        try confirmDeletion(app, email: email)
        let error = app.staticTexts["account-error"]
        XCTAssertTrue(error.waitForExistence(timeout: Wait.control))
        XCTAssertEqual(error.label,
                       "Transfer ownership of any household with other active roommates before deleting your account. Open Household members in Account.")
        let rejected = try await deletionState(email, seed)
        XCTAssertTrue(rejected.accountExists)
        XCTAssertFalse(rejected.pending)
        XCTAssertEqual(rejected.deletionAttempts, 0)
        XCTAssertEqual(rejected.households.map(\.ledgerDigest), before.households.map(\.ledgerDigest))
        try tap(app.buttons["Cancel"], in: app)
        try tap(app.buttons["Done"], in: app)
        try openMoney(app)
        XCTAssertTrue(app.otherElements["money-sheet"].exists)
        try tap(app.buttons["Done"], in: app)
    }
}
