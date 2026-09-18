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
    private(set) var chores: HouseholdChores?
    private(set) var choreCatalog: ChoreCatalog?
    private(set) var choreObjects: [ChoreObject] = []
    private(set) var choreCalendar: ChoreCalendar?
    private(set) var choresFailure: String?
    private(set) var choreSaveFailure = HouseholdSaveFailure.none
    private(set) var shopping: HouseholdShopping?
    private(set) var shoppingFailure: String?
    private(set) var shoppingSaveFailure = HouseholdSaveFailure.none
    var message: String?
    var notice: String?
    let setupError: String?

    private let client: AccountSession?
    private var deletionBlocked = false

    var signedIn: Bool { state?.isSignedIn == true }
    var deletionPending: Bool { deletionBlocked || state?.deletionPending == true }
    var householdName: String? { deletionPending ? nil : state?.session?.household.name }
    var canUseAccount: Bool { signedIn && !deletionPending }

    enum HouseholdSaveFailure {
        case none, retrySameChange, refreshRequired
    }

    init(client: AccountSession) {
        self.client = client
        setupError = nil
    }

    private init(setupError: String) {
        client = nil
        self.setupError = setupError
        message = setupError
    }

    static func live() -> AccountModel {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.roomlings.app"
        var origin = Bundle.main.object(forInfoDictionaryKey: "RoomlingsAPIOrigin") as? String ?? ""
        var service = "\(bundleID).account"
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["ROOMLINGS_API_ORIGIN"] { origin = configured }
        if let isolated = environment["ROOMLINGS_KEYCHAIN_SERVICE"] { service = isolated }
        #endif
        do {
            let configuration = try APIConfiguration(origin: origin)
            let originKey = SHA256.hash(data: Data(configuration.origin.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let store = try KeychainSessionTokenStore(service: "\(service).\(originKey)")
            return AccountModel(client: AccountSession(configuration: configuration, tokenStore: store))
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
    func refresh() async -> Bool {
        guard !busy else { return false }
        refreshing = true
        defer { refreshing = false }
        return await perform(.refresh) { try await $0.restore() }
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
        await perform(.join) { try await $0.acceptInvitation(code: code, memberName: memberName) }
    }

    func select(id: UUID) async -> Bool {
        await perform(.select) { try await $0.selectHousehold(id: id) }
    }

    func signOut() async -> Bool {
        await perform(.logout) { try await $0.logout() }
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
            return published
        } catch {
            await failed(error, action: action, client: client)
            return false
        }
    }

    private func publish(_ next: AccountState?) -> Bool {
        state = next
        roomFailure = nil
        chores = nil
        choreObjects = []
        choreCalendar = nil
        choresFailure = nil
        shopping = nil
        shoppingFailure = nil
        guard !deletionPending, let household = next?.session?.household else {
            room = .preview
            return true
        }
        do {
            shopping = try HouseholdShopping(household: household)
        } catch {
            shoppingFailure = "Your shopping list could not be displayed. Refresh shopping before making changes."
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
        _ = publish(latest)
        if action.isChore || action == .shopping {
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
            else { shoppingSaveFailure = failure }
        }
        message = Self.message(for: error, action: action)
    }

    private enum Action {
        case refresh, sendCode, verify, recover, create, join, select, logout, addChore, completeChore, undoChore, shopping

        var isChore: Bool { self == .addChore || self == .completeChore || self == .undoChore }
    }

    private static func message(for error: Error, action: Action) -> String {
        if action.isChore || action == .shopping { return mutationMessage(for: error, shopping: action == .shopping) }
        if error is CancellationError { return "The request stopped. Refresh your account before repeating it." }
        if error is KeychainError || (error as? AccountError) == .credentialStorage {
            return "Saved access could not be updated securely. Unlock the device and try again."
        }
        guard let error = error as? AccountError else { return "The account action could not be completed. Try again." }
        switch error {
        case .network:
            return "Could not reach Roomlings. Your saved access is unchanged. Try again."
        case .server(let status, let code):
            if code == .accountDeletionPending { return "Account deletion is pending. Finish it on the web, or sign out here." }
            if code == .authNotConfigured { return "Account access is not configured on this server." }
            if code == .authProviderUnavailable { return "Email sign-in is unavailable right now. Try again or use an unused recovery code." }
            if code == .accountSessionRequired { return "Your session has expired. Sign in again." }
            if code == .reauthenticationRequired { return "Sign in again before continuing this action." }
            if status == 429 { return "Too many attempts. Wait a few minutes before trying again." }
            if status >= 500 { return "Roomlings is temporarily unavailable. Your saved access is unchanged." }
            if action == .join {
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
        default:
            return "The server response could not be used. Your saved access is unchanged."
        }
    }

    private static func mutationMessage(for error: Error, shopping: Bool) -> String {
        let resource = shopping ? "shopping" : "chores"
        if error is KeychainError || (error as? AccountError) == .credentialStorage {
            return "Saved access could not be read securely. Unlock the device and try again."
        }
        switch error {
        case AccountError.server(_, .some(.accountSessionRequired)):
            return "Your session has expired. Sign in again."
        case AccountError.server(_, .some(.accountDeletionPending)):
            return "Account deletion is pending. Finish it on the web, or sign out here."
        case AccountError.server(_, .some(.reauthenticationRequired)):
            return "Sign in again before changing \(resource)."
        case AccountError.server(409, let code):
            return code == .mutationTooOld
                ? "This save is too old to confirm. Refresh \(resource) and review the current list."
                : "\(shopping ? "Shopping" : "Chores") changed elsewhere. Refresh \(resource) and review the latest state before trying again."
        case AccountError.server(let status, _) where status == 403 || status == 404:
            return "This \(shopping ? "item" : "chore") or household is no longer available. Refresh \(resource) before trying again."
        case AccountError.server(429, _):
            return "Too many changes. Wait a moment before retrying this save."
        case AccountError.invalidInput, AccountError.server(400, _):
            return shopping ? "Check the item name, quantity and notes, then review its current claim."
                : "Check the chore name, date, repeat interval, object and active roommates."
        case AccountError.accountStateRequired, AccountError.householdSelectionChanged:
            return "Your selected household changed. Refresh \(resource) and review the current household before continuing."
        case AccountError.operationInProgress:
            return "Another Roomlings request is still running."
        default:
            return "Could not confirm the \(shopping ? "shopping" : "chore") save. Retry the same change or refresh \(resource) before trying anything else."
        }
    }
}
