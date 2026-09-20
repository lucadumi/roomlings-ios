import CryptoKit
import Foundation
import Observation
import RoomlingsCore

@MainActor @Observable
final class AccountModel {
    private(set) var state: AccountState?
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var restored = false
    private(set) var room = RoomVisualState.preview
    private(set) var roomFailure: String?
    private(set) var viewer: HouseholdMember?
    private(set) var viewerFailure: String?
    private(set) var chores: HouseholdChores?
    private(set) var choreCatalog: ChoreCatalog?
    private(set) var choreObjects: [ChoreObject] = []
    private(set) var choreCalendar: ChoreCalendar?
    private(set) var choresFailure: String?
    private(set) var choreSaveFailure = HouseholdSaveFailure.none
    private(set) var shopping: HouseholdShopping?
    private(set) var shoppingFailure: String?
    private(set) var shoppingSaveFailure = HouseholdSaveFailure.none
    private(set) var ledger: HouseholdLedger?
    private(set) var ledgerFailure: String?
    private(set) var ledgerSaveFailure = HouseholdSaveFailure.none
    private(set) var invitations: HouseholdInvitationAccess?
    private(set) var invitationLink: URL?
    private(set) var invitationNeedsRefresh = false
    private(set) var pendingInvitation: AccountInvitationCode?
    private(set) var incomingInvitationError: String?
    var message: String?
    var notice: String?
    var notificationFailure: String?
    let setupError: String?
    let invitationOrigin: APIConfiguration?
    let notificationStore: (any PushInstallationStore)?

    private let client: AccountSession?
    private let analytics: NativeAnalytics?
    private var deletionBlocked = false
    private var sharedInvitationID: UUID?
    private var requestFailed = false

    var signedIn: Bool { state?.isSignedIn == true }
    var deletionPending: Bool { deletionBlocked || state?.deletionPending == true }
    var householdName: String? { deletionPending ? nil : state?.session?.household.name }
    var viewerColor: HouseholdMemberColor? { viewer.flatMap { HouseholdMemberColor(hex: $0.color) } }
    var canUseAccount: Bool { signedIn && !deletionPending }
    var analyticsContext: AnalyticsContext? { analytics?.context }
    var headerStatus: HeaderStatus {
        if busy { return .updating }
        if requestFailed || setupError != nil || deletionPending || viewerFailure != nil
            || roomFailure != nil || choresFailure != nil || shoppingFailure != nil || ledgerFailure != nil
            || notificationFailure != nil {
            return .needsAttention
        }
        return householdName == nil ? .preview : .loaded
    }
    var invitationSetupError: String? {
        invitationOrigin == nil
            ? "Invitation links are not configured in this build. Set the Roomlings invitation origin in Xcode."
            : nil
    }

    func canShareInvitation(at date: Date) -> Bool {
        !invitationNeedsRefresh && invitationLink != nil
            && invitations?.invitations.contains(where: { $0.id == sharedInvitationID && $0.isPending(at: date) }) == true
    }

    enum HouseholdSaveFailure {
        case none, retrySameChange, refreshRequired
    }

    enum HeaderStatus {
        case preview, updating, loaded, needsAttention

        var label: String {
            switch self {
            case .preview: "Kitchen preview"
            case .updating: "Updating account"
            case .loaded: "Household loaded"
            case .needsAttention: "Account needs attention"
            }
        }
    }

    init(client: AccountSession, invitationOrigin: APIConfiguration? = nil,
         notificationStore: (any PushInstallationStore)? = nil, analytics: NativeAnalytics? = nil) {
        self.client = client
        self.analytics = analytics
        self.invitationOrigin = invitationOrigin
        self.notificationStore = notificationStore
        setupError = nil
    }

    private init(setupError: String) {
        client = nil
        analytics = nil
        invitationOrigin = nil
        notificationStore = nil
        self.setupError = setupError
        message = setupError
    }

    static func live() -> AccountModel {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.roomlings.app"
        var origin = Bundle.main.object(forInfoDictionaryKey: "RoomlingsAPIOrigin") as? String ?? ""
        var invitationOrigin = Bundle.main.object(forInfoDictionaryKey: "RoomlingsInvitationOrigin") as? String ?? ""
        var service = "\(bundleID).account"
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["ROOMLINGS_API_ORIGIN"] { origin = configured }
        if let configured = environment["ROOMLINGS_INVITATION_ORIGIN"] { invitationOrigin = configured }
        if let isolated = environment["ROOMLINGS_KEYCHAIN_SERVICE"] { service = isolated }
        #endif
        do {
            let configuration = try APIConfiguration(origin: origin)
            let originKey = SHA256.hash(data: Data(configuration.origin.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let store = try KeychainSessionTokenStore(service: "\(service).\(originKey)")
            let notifications = try KeychainPushInstallationStore(service: "\(service).\(originKey)")
            let client = AccountSession(configuration: configuration, tokenStore: store)
            let analytics = NativeAnalytics(client: client)
            do {
                return AccountModel(client: client, invitationOrigin: try APIConfiguration(origin: invitationOrigin),
                                    notificationStore: notifications, analytics: analytics)
            } catch {
                // Account access remains usable; invitationSetupError explains the missing link configuration.
                return AccountModel(client: client, notificationStore: notifications, analytics: analytics)
            }
        } catch {
            return AccountModel(setupError: "Account access is not configured. Set the Roomlings API origin in Xcode and rebuild the app.")
        }
    }

    func start() async {
        guard !restored else { return }
        restored = true
        _ = await refresh()
    }

    @discardableResult
    func refresh(includeInvitations: Bool = false) async -> Bool {
        guard !busy else { return false }
        refreshing = true
        defer { refreshing = false }
        let refreshed = await perform(.refresh) { try await $0.restore() }
        if refreshed, includeInvitations, canUseAccount, state?.session != nil {
            return await loadInvitations()
        }
        return refreshed
    }

    func sendCode(email: String) async -> Bool {
        guard let client, begin() else { return false }
        defer { busy = false }
        do {
            try await client.sendEmailCode(email: email)
            notice = "Check your email for a sign-in code."
            return true
        } catch {
            await failed(error, action: .sendCode, client: client)
            return false
        }
    }

    func verify(email: String, code: String, name: String, label: String) async -> Bool {
        await perform(.verify) {
            try await $0.verifyEmailCode(email: email, code: code, name: name, deviceLabel: label)
        }
    }

    func recover(email: String, code: String, label: String) async -> Bool {
        await perform(.recover) {
            try await $0.recover(email: email, recoveryCode: code, deviceLabel: label)
        }
    }

    func create(name: String, memberName: String, currency: HouseholdCurrency, budget: Int64, requestID: UUID) async -> Bool {
        await perform(.create) {
            try await $0.createHousehold(name: name, memberName: memberName, currency: currency, budgetCents: budget, requestID: requestID)
        }
    }

    func join(code: String, memberName: String) async -> Bool {
        let originalInvitation = pendingInvitation
        let previousHouseholds = Set(state?.memberships.map(\.householdID) ?? [])
        let saved = await perform(.join) { try await $0.acceptInvitation(code: code, memberName: memberName) }
        if saved, let context = analyticsContext, !previousHouseholds.contains(context.householdID) {
            analytics?.record(.inviteAccepted, context: context)
        }
        if saved, pendingInvitation == originalInvitation {
            dismissInvitation()
        }
        return saved
    }

    func select(id: UUID) async -> Bool {
        await perform(.select) { try await $0.selectHousehold(id: id) }
    }

    func signOut() async -> Bool {
        let signedOut = await perform(.logout) { try await $0.logout() }
        if signedOut { dismissInvitation() }
        return signedOut
    }

    func analyticsBecameActive() { analytics?.becameActive() }
    func analyticsEnteredBackground() { analytics?.enteredBackground() }

    func invitationSharingFinished(context: AnalyticsContext?, completed: Bool, failed: Bool) {
        if failed {
            message = "The invitation could not be shared. Try sharing the link again."
        } else if completed, let context {
            analytics?.record(.inviteShared, context: context)
        }
    }

    func recordNotificationOpened(householdID: UUID, at date: Date) {
        guard let context = analyticsContext, context.householdID == householdID else { return }
        analytics?.record(.notificationOpened, context: context, at: date)
    }

    func loadNotificationSettings(householdID: UUID) async throws -> HouseholdNotificationSettings {
        try await notificationOperation { try await $0.loadNotificationSettings(householdID: householdID) }
    }

    func saveNotificationSettings(
        _ preferences: NotificationPreferences, householdID: UUID
    ) async throws -> HouseholdNotificationSettings {
        try await notificationOperation {
            try await $0.saveNotificationSettings(preferences, householdID: householdID)
        }
    }

    func registerPushDevice(installationID: UUID, token: APNsDeviceToken, environment: APNsEnvironment) async throws {
        try await notificationOperation {
            try await $0.registerPushDevice(installationID: installationID, token: token, environment: environment)
        }
    }

    func unregisterPushDevice(installationID: UUID) async throws {
        try await notificationOperation { try await $0.unregisterPushDevice(installationID: installationID) }
    }

    private func notificationOperation<Result: Sendable>(
        _ operation: @Sendable (AccountSession) async throws -> Result
    ) async throws -> Result {
        guard let client, canUseAccount else { throw AccountError.accountStateRequired }
        guard !busy else { throw AccountError.operationInProgress }
        busy = true
        defer { busy = false }
        do {
            return try await operation(client)
        } catch {
            if case AccountError.server(_, .some(.accountDeletionPending)) = error { deletionBlocked = true }
            let latest = await client.state
            if latest != state || deletionBlocked { _ = publish(latest, requestFailed: true) }
            throw error
        }
    }

    func receiveInvitation(_ url: URL) {
        guard let invitationOrigin else {
            pendingInvitation = nil
            incomingInvitationError = invitationSetupError
            return
        }
        do {
            pendingInvitation = try AccountInvitationCode(link: url, origin: invitationOrigin)
            incomingInvitationError = nil
        } catch {
            pendingInvitation = nil
            incomingInvitationError = "This is not a valid invitation from the configured Roomlings website. Ask the owner for a current link."
        }
    }

    func dismissInvitation() {
        pendingInvitation = nil
        incomingInvitationError = nil
    }

    func clearInvitationLink() {
        invitationLink = nil
        sharedInvitationID = nil
    }

    @discardableResult
    func loadInvitations() async -> Bool {
        guard canUseAccount, let householdID = state?.session?.household.id else {
            message = "Open your household before loading its invitations."
            return false
        }
        guard let client, begin() else { return false }
        defer { busy = false }
        do {
            let access = try await client.loadInvitations(householdID: householdID)
            return acceptInvitations(access, state: await client.state)
        } catch {
            await failed(error, action: .invitationLoad, client: client)
            invitationNeedsRefresh = true
            return false
        }
    }

    func createInvitation(householdID: UUID, version: Int64) async -> Bool {
        guard !invitationNeedsRefresh else {
            message = "Refresh invitations before making another change."
            return false
        }
        guard let invitationOrigin else {
            message = invitationSetupError
            return false
        }
        guard let client, begin() else { return false }
        defer { busy = false }
        clearInvitationLink()
        do {
            let result = try await client.createInvitation(householdID: householdID, version: version)
            let link = try result.code.link(origin: invitationOrigin)
            let published = acceptInvitations(result.access, state: await client.state)
            sharedInvitationID = result.invitation.id
            invitationLink = link
            notice = "Invitation created. Share it now; the link is only available this time."
            return published
        } catch {
            await failed(error, action: .invitationCreate, client: client)
            invitationNeedsRefresh = true
            return false
        }
    }

    func revokeInvitation(id: UUID, householdID: UUID, version: Int64) async -> Bool {
        guard !invitationNeedsRefresh else {
            message = "Refresh invitations before making another change."
            return false
        }
        guard let client, begin() else { return false }
        defer { busy = false }
        do {
            let access = try await client.revokeInvitation(id: id, householdID: householdID, version: version)
            let published = acceptInvitations(access, state: await client.state)
            notice = "Invitation revoked. People who already joined keep their membership."
            return published
        } catch {
            await failed(error, action: .invitationRevoke, client: client)
            invitationNeedsRefresh = true
            return false
        }
    }

    private func acceptInvitations(_ access: HouseholdInvitationAccess, state: AccountState?) -> Bool {
        let published = publish(state)
        invitations = access
        invitationNeedsRefresh = false
        if access.role != .owner || !access.invitations.contains(where: { $0.id == sharedInvitationID && $0.isPending() }) {
            clearInvitationLink()
        }
        return published
    }

    func addChore(_ draft: ChoreDraft, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        let saved = await perform(.addChore) {
            try await $0.addChore(draft, householdID: householdID, version: version, mutationID: mutationID)
        }
        if saved { notice = "Chore added." }
        return saved
    }

    func completeChore(_ chore: Chore, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        let saved = await perform(.completeChore) {
            try await $0.completeChore(id: chore.id, choreVersion: chore.version,
                                      householdID: householdID, version: version, mutationID: mutationID)
        }
        if saved { notice = "Chore completed." }
        return saved
    }

    func undoChoreCompletion(_ completion: ChoreCompletion, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        let saved = await perform(.undoChore) {
            try await $0.undoChoreCompletion(id: completion.id, choreVersion: completion.resultVersion,
                                            householdID: householdID, version: version, mutationID: mutationID)
        }
        if saved { notice = "Chore completion undone." }
        return saved
    }

    func addShoppingItem(_ draft: ShoppingDraft, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveShopping("Shopping item added.") {
            try await $0.addShoppingItem(draft, householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func editShoppingItem(_ item: ShoppingItem, draft: ShoppingDraft, householdID: UUID,
                          version: Int64, mutationID: UUID) async -> Bool {
        await saveShopping("Shopping item updated.") {
            try await $0.editShoppingItem(id: item.id, draft: draft, itemVersion: item.version,
                                         householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func removeShoppingItem(_ item: ShoppingItem, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveShopping("Shopping item removed.") {
            try await $0.removeShoppingItem(id: item.id, itemVersion: item.version,
                                           householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func claimShoppingItem(_ item: ShoppingItem, claim: Bool, householdID: UUID,
                           version: Int64, mutationID: UUID) async -> Bool {
        await saveShopping(claim ? "Shopping item claimed." : "Shopping claim released.") {
            try await $0.claimShoppingItem(id: item.id, claim: claim, itemVersion: item.version,
                                          householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func pickShoppingItem(_ item: ShoppingItem, pickedUp: Bool, householdID: UUID,
                          version: Int64, mutationID: UUID) async -> Bool {
        await saveShopping(pickedUp ? "Item picked up. No expense was created." : "Item returned to the list.") {
            try await $0.pickShoppingItem(id: item.id, pickedUp: pickedUp, itemVersion: item.version,
                                         householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    private func saveShopping(_ notice: String, operation: @Sendable (AccountSession) async throws -> AccountState) async -> Bool {
        let saved = await perform(.shopping, operation: operation)
        if saved { self.notice = notice }
        return saved
    }

    func recordExpense(_ draft: ExpenseDraft, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveLedger("Receipt recorded.") {
            try await $0.recordExpense(draft, householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func checkoutShopping(_ draft: ExpenseDraft, checkoutID: UUID, selection: [ShoppingSelection],
                          householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveLedger("Receipt recorded and the basket cleared.") {
            try await $0.checkoutShopping(draft, checkoutID: checkoutID, selection: selection,
                                          householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func removeExpense(_ expense: HouseholdExpense, householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveLedger("Receipt removed from the ledger.") {
            try await $0.removeExpense(id: expense.id, householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func recordSettlement(from: UUID, to: UUID, amount: Int64,
                          householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveLedger("Repayment recorded. Roomlings tracks it; no money moved.") {
            try await $0.recordSettlement(from: from, to: to, amount: amount,
                                          householdID: householdID, version: version, mutationID: mutationID)
        }
    }

    func removeSettlement(_ settlement: HouseholdSettlement,
                          householdID: UUID, version: Int64, mutationID: UUID) async -> Bool {
        await saveLedger("Repayment undone.") {
            try await $0.removeSettlement(id: settlement.id, householdID: householdID,
                                          version: version, mutationID: mutationID)
        }
    }

    private func saveLedger(_ notice: String, operation: @Sendable (AccountSession) async throws -> AccountState) async -> Bool {
        let saved = await perform(.ledger, operation: operation)
        if saved { self.notice = notice }
        return saved
    }

    func clearFeedback() {
        message = nil
        notice = nil
    }

    private func begin() -> Bool {
        guard !busy else { return false }
        if let setupError {
            message = setupError
            return false
        }
        busy = true
        clearFeedback()
        return true
    }

    private func perform(_ action: Action, operation: @Sendable (AccountSession) async throws -> AccountState) async -> Bool {
        guard let client, begin() else { return false }
        defer { busy = false }
        if action.isChore { choreSaveFailure = .none }
        if action == .shopping { shoppingSaveFailure = .none }
        if action == .ledger { ledgerSaveFailure = .none }
        do {
            let next = try await operation(client)
            deletionBlocked = next.deletionPending
            let published = publish(next)
            if action.isChore, let choresFailure {
                message = choresFailure
                choreSaveFailure = .retrySameChange
                return false
            }
            if action == .shopping, let shoppingFailure {
                message = shoppingFailure
                shoppingSaveFailure = .retrySameChange
                return false
            }
            if action == .ledger, let ledgerFailure {
                message = ledgerFailure
                ledgerSaveFailure = .retrySameChange
                return false
            }
            return published
        } catch {
            await failed(error, action: action, client: client)
            return false
        }
    }

    private func publish(_ next: AccountState?, requestFailed: Bool = false) -> Bool {
        defer { analytics?.updateAccount(deletionPending ? nil : state) }
        if next?.account?.id != state?.account?.id || next?.session?.household.id != state?.session?.household.id
            || next?.isSignedIn != true || deletionBlocked || next?.deletionPending == true {
            invitations = nil
            invitationNeedsRefresh = false
            clearInvitationLink()
        } else if let invitations, invitations.household.version != next?.session?.household.version {
            invitationNeedsRefresh = true
        }
        state = next
        self.requestFailed = requestFailed
        roomFailure = nil
        viewer = nil
        viewerFailure = nil
        chores = nil
        choreObjects = []
        choreCalendar = nil
        choresFailure = nil
        shopping = nil
        shoppingFailure = nil
        ledger = nil
        ledgerFailure = nil
        guard !deletionPending, let session = next?.session else {
            room = .preview
            return true
        }
        let household = session.household
        do {
            viewer = try session.viewer
            if viewerColor == nil {
                viewerFailure = "Your saved member colour could not be displayed. Refresh your account."
            }
        } catch {
            viewerFailure = "Your household member could not be displayed. Refresh your account."
        }
        do {
            shopping = try HouseholdShopping(household: household)
        } catch {
            shoppingFailure = "Your shopping list could not be displayed. Refresh shopping before making changes."
        }
        do {
            ledger = try HouseholdLedger(household: household)
        } catch {
            ledgerFailure = "Your recorded receipts could not be displayed. Refresh shopping before recording another."
        }
        do {
            let catalog = try choreCatalog ?? ChoreCatalog.load()
            choreCatalog = catalog
            let board = try HouseholdChores(household: household)
            let objects = try catalog.objects(in: household)
            let calendar = try ChoreCalendar(chores: board)
            chores = board
            choreObjects = objects
            choreCalendar = calendar
        } catch {
            choresFailure = "Your chores could not be displayed. Refresh chores. If this continues, rebuild the app with the shared web source."
        }
        do {
            room = try RoomVisualState(household: household)
            return true
        } catch {
            room = .preview
            roomFailure = "Your household is saved, but its room data could not be displayed. Refresh your account."
            message = roomFailure
            return false
        }
    }

    private func failed(_ error: Error, action: Action, client: AccountSession) async {
        if case AccountError.server(_, .some(.accountDeletionPending)) = error {
            deletionBlocked = true
        }
        let latest = await client.state
        if latest?.isSignedIn != true { deletionBlocked = false }
        _ = publish(latest, requestFailed: true)
        if action.isChore || action == .shopping || action == .ledger {
            let failure: HouseholdSaveFailure
            switch error {
            case AccountError.server(let status, _) where [403, 404, 409].contains(status):
                failure = .refreshRequired
            case AccountError.accountStateRequired, AccountError.householdSelectionChanged:
                failure = .refreshRequired
            case AccountError.server(let status, _) where status < 500 && status != 429:
                failure = .none
            case AccountError.invalidInput, AccountError.operationInProgress, AccountError.credentialStorage, is KeychainError:
                failure = .none
            default:
                failure = .retrySameChange
            }
            if action.isChore { choreSaveFailure = failure }
            else if action == .shopping { shoppingSaveFailure = failure }
            else { ledgerSaveFailure = failure }
        }
        message = Self.message(for: error, action: action)
    }

    private enum Action {
        case refresh, sendCode, verify, recover, create, join, select, logout
        case addChore, completeChore, undoChore, shopping, ledger
        case invitationLoad, invitationCreate, invitationRevoke

        var isChore: Bool { self == .addChore || self == .completeChore || self == .undoChore }
        var isInvitation: Bool { self == .invitationLoad || isInvitationMutation }
        var isInvitationMutation: Bool { self == .invitationCreate || self == .invitationRevoke }

        var resource: Resource? {
            if isChore { return .chores }
            if self == .shopping { return .shopping }
            return self == .ledger ? .ledger : nil
        }
    }

    /// Wording for the household collection a failed mutation touched.
    private enum Resource {
        case chores, shopping, ledger

        var name: String {
            switch self {
            case .chores: "chores"
            case .shopping: "shopping"
            case .ledger: "receipts"
            }
        }

        var subject: String {
            switch self {
            case .chores: "Chores"
            case .shopping: "Shopping"
            case .ledger: "Receipts"
            }
        }

        var item: String {
            switch self {
            case .chores: "chore"
            case .shopping: "item"
            case .ledger: "receipt"
            }
        }

        var save: String {
            switch self {
            case .chores: "chore"
            case .shopping: "shopping"
            case .ledger: "receipt"
            }
        }

        var advice: String {
            switch self {
            case .chores: "Check the chore name, date, repeat interval, object and active roommates."
            case .shopping: "Check the item name, quantity and notes, then review its current claim."
            case .ledger: "Check the description, amount, who paid, the split and the date."
            }
        }
    }

    private static func message(for error: Error, action: Action) -> String {
        if let resource = action.resource { return mutationMessage(for: error, resource: resource) }
        if error is CancellationError {
            return action.isInvitationMutation
                ? "The invitation change could not be confirmed. Refresh invitations before making another change."
                : "The request stopped. Refresh your account before repeating it."
        }
        if error is KeychainError || (error as? AccountError) == .credentialStorage {
            return "Saved access could not be updated securely. Unlock the device and try again."
        }
        guard let error = error as? AccountError else { return "The account action could not be completed. Try again." }
        switch error {
        case .network:
            if action.isInvitation {
                return action.isInvitationMutation
                    ? "The invitation change could not be confirmed. Refresh invitations before making another change. A new link cannot be fetched again."
                    : "Could not load invitations. Check your connection and refresh invitations."
            }
            return "Could not reach Roomlings. Your saved access is unchanged. Try again."
        case .server(let status, let code):
            if code == .accountDeletionPending { return "Account deletion is pending. Finish it on the web, or sign out here." }
            if code == .authNotConfigured { return "Account access is not configured on this server." }
            if code == .authProviderUnavailable { return "Email sign-in is unavailable right now. Try again or use an unused recovery code." }
            if code == .accountSessionRequired { return "Your session has expired. Sign in again." }
            if code == .reauthenticationRequired { return "Sign in again before continuing this action." }
            if status == 429 { return "Too many attempts. Wait a few minutes before trying again." }
            if action.isInvitation {
                if status == 403 { return "Only the household owner can manage invitations. Refresh your account to check your access." }
                if status == 409 {
                    return "Invitations changed elsewhere or the active invitation limit was reached. Refresh invitations and review the pending links."
                }
                if status == 404 { return "That invitation or household is no longer available. Refresh invitations." }
                if status >= 500 {
                    return "The invitation request could not be confirmed. Refresh invitations before making another change."
                }
            }
            if status >= 500 { return "Roomlings is temporarily unavailable. Your saved access is unchanged." }
            if action == .join {
                if status == 410 { return "That invitation is invalid, expired or revoked. Ask the owner for a new link." }
                if status == 409 {
                    return "That name may already be taken, or a household or account limit was reached. Try another name or ask the owner to check."
                }
                return status == 400 ? "Check the invitation and your name in this household."
                    : "That invitation cannot be used. Ask the owner for a current invitation link."
            }
            if status == 401 {
                return action == .recover ? "That recovery code is invalid or already used. Try another unused code."
                    : "That email code is invalid or expired. Request a new code."
            }
            if status == 403 { return "You no longer have access to that household. Refresh your account." }
            if status == 409 { return "The account changed elsewhere. Refresh it before trying again." }
            return "Check the details and try again."
        case .invalidInput:
            return "Check the details. Names must be 1 to 50 characters, and codes must be complete."
        case .operationInProgress:
            return "Another account action is still running."
        case .accountStateRequired, .householdSelectionChanged:
            return "Your household access changed. Refresh your account before continuing."
        default:
            if action.isInvitation {
                return "The invitation response could not be used. Refresh invitations before making another change."
            }
            return "The server response could not be used. Your saved access is unchanged."
        }
    }

    private static func mutationMessage(for error: Error, resource: Resource) -> String {
        let name = resource.name
        if error is KeychainError || (error as? AccountError) == .credentialStorage {
            return "Saved access could not be read securely. Unlock the device and try again."
        }
        switch error {
        case AccountError.server(_, .some(.accountSessionRequired)):
            return "Your session has expired. Sign in again."
        case AccountError.server(_, .some(.accountDeletionPending)):
            return "Account deletion is pending. Finish it on the web, or sign out here."
        case AccountError.server(_, .some(.reauthenticationRequired)):
            return "Sign in again before changing \(name)."
        case AccountError.server(409, let code):
            return code == .mutationTooOld
                ? "This save is too old to confirm. Refresh \(name) and review the current list."
                : "\(resource.subject) changed elsewhere. Refresh \(name) and review the latest state before trying again."
        case AccountError.server(let status, _) where status == 403 || status == 404:
            return "This \(resource.item) or household is no longer available. Refresh \(name) before trying again."
        case AccountError.server(429, _):
            return "Too many changes. Wait a moment before retrying this save."
        case AccountError.invalidInput, AccountError.server(400, _):
            return resource.advice
        case AccountError.accountStateRequired, AccountError.householdSelectionChanged:
            return "Your selected household changed. Refresh \(name) and review the current household before continuing."
        case AccountError.operationInProgress:
            return "Another Roomlings request is still running."
        default:
            return "Could not confirm the \(resource.save) save. Retry the same change or refresh \(name) before trying anything else."
        }
    }
}
