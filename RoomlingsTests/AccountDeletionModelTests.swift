import XCTest
import RoomlingsCore
@testable import Roomlings

@MainActor
final class AccountDeletionModelTests: XCTestCase {
    private let fixture = InvitationModelFixture()
    private let accountID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let email = "ada@example.test"

    func testConfirmedDeletionClearsHouseholdDataAndAccountBoundPushConsent() async throws {
        let setup = try await make([fixture.state(signedIn: false)])
        XCTAssertNotNil(setup.model.room.householdID)
        let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertTrue(deleted)
        XCTAssertFalse(setup.model.signedIn)
        XCTAssertFalse(setup.model.canUseAccount)
        XCTAssertNil(setup.model.room.householdID)
        XCTAssertNil(setup.model.chores)
        XCTAssertNil(setup.model.shopping)
        XCTAssertNil(setup.model.ledger)
        XCTAssertEqual(setup.model.notice, "Account deleted. Shared ledger history kept.")
        let installation = await setup.push.value
        XCTAssertNil(installation)
        XCTAssertFalse(setup.model.deletionCleanupRequired)
    }

    func testIncorrectEmailCannotSendADeletionRequest() async throws {
        let setup = try await make([])
        for confirmation in ["Ada@example.test", "ada@example.test ", "someone@example.test"] {
            let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: confirmation)
            XCTAssertFalse(deleted)
        }
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(setup.model.canUseAccount)
        XCTAssertEqual(setup.model.deletionStatus, .none)
    }

    func testOwnershipRejectionKeepsTheHouseholdAndExplainsTheHandoff() async throws {
        let setup = try await make([fixture.failure(409, code: "OWNERSHIP_TRANSFER_REQUIRED")])
        let household = setup.model.state?.session?.household
        let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(deleted)
        XCTAssertTrue(setup.model.canUseAccount)
        XCTAssertEqual(setup.model.state?.session?.household, household)
        XCTAssertTrue(setup.model.message?.contains("Transfer ownership") == true)
        XCTAssertFalse(setup.model.accountDeletionConfirmed)
    }

    func testReverificationNeverResendsDeletionAutomatically() async throws {
        let setup = try await make([
            fixture.failure(401, code: "REAUTHENTICATION_REQUIRED"), fixture.state(token: true)
        ])
        let rejected = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(rejected)
        XCTAssertTrue(setup.model.deletionRequiresReauthentication)
        let verified = await setup.model.reauthenticate(accountID: accountID, code: "123456", label: "My phone")
        XCTAssertTrue(verified)
        XCTAssertFalse(setup.model.deletionRequiresReauthentication)
        XCTAssertTrue(setup.model.canUseAccount)
        XCTAssertTrue(setup.model.notice?.contains("Review the deletion warning") == true)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    func testPendingDeletionHidesHouseholdAccessUntilExplicitRetryCompletes() async throws {
        let setup = try await make([
            fixture.failure(503, code: "ACCOUNT_DELETION_PENDING"),
            fixture.state(selectedHousehold: false, deletionPending: true),
            fixture.state(signedIn: false)
        ])
        let failed = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(failed)
        XCTAssertTrue(setup.model.deletionPending)
        XCTAssertFalse(setup.model.canUseAccount)
        XCTAssertNil(setup.model.room.householdID)
        XCTAssertNil(setup.model.ledger)
        XCTAssertNil(setup.model.notice)
        let refreshed = await setup.model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertTrue(setup.model.deletionPending)
        let retried = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertTrue(retried)
        XCTAssertFalse(setup.model.signedIn)
        XCTAssertFalse(setup.model.deletionPending)
    }

    func testAnUnknownOutcomeBlocksActionsUntilAnAccountRefresh() async throws {
        let setup = try await make([fixture.failure(500), fixture.state()])
        let failed = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(failed)
        XCTAssertTrue(setup.model.deletionNeedsRefresh)
        XCTAssertFalse(setup.model.canUseAccount)
        XCTAssertNil(setup.model.room.householdID)
        let blindlyRetried = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(blindlyRetried)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 2)
        let refreshed = await setup.model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(setup.model.deletionNeedsRefresh)
        XCTAssertTrue(setup.model.canUseAccount)
    }

    func testEndedAccessAfterALostResponseDoesNotMasqueradeAsConfirmedDeletion() async throws {
        let setup = try await make([fixture.failure(500), fixture.state(signedIn: false)])
        _ = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        let refreshed = await setup.model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(setup.model.accountDeletionConfirmed)
        XCTAssertEqual(setup.model.notice, "Account access has ended. Pending deletions continue on the server.")
    }

    func testCredentialCleanupFailureDoesNotRepeatTheRemoteDeletion() async throws {
        let setup = try await make([fixture.state(signedIn: false)])
        await setup.credentials.setClearFailure(true)
        let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(deleted)
        XCTAssertTrue(setup.model.deletionCleanupRequired)
        XCTAssertFalse(setup.model.canUseAccount)
        XCTAssertNil(setup.model.notice)
        await setup.credentials.setClearFailure(false)
        let cleared = await setup.model.finishAccountDeletionCleanup()
        XCTAssertTrue(cleared)
        XCTAssertFalse(setup.model.deletionCleanupRequired)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 2)
        let installation = await setup.push.value
        XCTAssertNil(installation)
    }

    func testPushConsentCleanupFailureStaysVisibleUntilItIsActuallyCleared() async throws {
        let setup = try await make([fixture.state(signedIn: false)])
        await setup.push.setClearFailure(true)
        let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertFalse(deleted)
        XCTAssertTrue(setup.model.accountDeletionConfirmed)
        XCTAssertTrue(setup.model.deletionCleanupRequired)
        XCTAssertNil(setup.model.notice)
        XCTAssertTrue(setup.model.message?.contains("saved access could not be cleared") == true)
        await setup.push.setClearFailure(false)
        let cleared = await setup.model.finishAccountDeletionCleanup()
        XCTAssertTrue(cleared)
        XCTAssertFalse(setup.model.deletionCleanupRequired)
        let requests = await setup.transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testDeletionCannotEraseAnotherAccountsNotificationConsent() async throws {
        let setup = try await make([fixture.state(signedIn: false)], pushAccountID: UUID())
        let original = await setup.push.value
        let deleted = await setup.model.deleteAccount(accountID: accountID, confirmation: email)
        XCTAssertTrue(deleted)
        let remaining = await setup.push.value
        XCTAssertEqual(remaining, original)
    }

    private func make(_ responses: [HTTPResponse], pushAccountID: UUID? = nil) async throws
        -> (model: AccountModel, transport: InvitationModelTransport,
            credentials: DeletionCredentialStore, push: DeletionPushStore) {
        let transport = InvitationModelTransport(responses: try [fixture.state()] + responses, holdIndex: nil)
        let credentials = DeletionCredentialStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let push = DeletionPushStore(value: PushInstallation(id: UUID(), enabled: true, accountID: pushAccountID ?? accountID))
        let client = AccountSession(configuration: fixture.api, tokenStore: credentials, transport: transport)
        let model = AccountModel(client: client, notificationStore: push)
        await model.start()
        return (model, transport, credentials, push)
    }
}

private actor DeletionCredentialStore: SessionTokenStore {
    private var token: SessionToken?
    private var fails = false
    init(token: SessionToken) { self.token = token }
    func read() -> SessionToken? { token }
    func save(_ token: SessionToken) { self.token = token }
    func clear() throws {
        if fails { throw AccountError.credentialStorage }
        token = nil
    }
    func setClearFailure(_ fails: Bool) { self.fails = fails }
}

private actor DeletionPushStore: PushInstallationStore {
    private(set) var value: PushInstallation?
    private var fails = false
    init(value: PushInstallation) { self.value = value }
    func read() -> PushInstallation? { value }
    func save(_ value: PushInstallation) { self.value = value }
    func clear() throws {
        if fails { throw AccountError.credentialStorage }
        value = nil
    }
    func setClearFailure(_ fails: Bool) { self.fails = fails }
}
