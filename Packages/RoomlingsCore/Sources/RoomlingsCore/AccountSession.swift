import Foundation

/// Own one coordinator per Keychain entry. Overlapping operations fail rather than race token writes.
public actor AccountSession {
    public private(set) var state: AccountState?
    public private(set) var isBusy = false
    public private(set) var deletionStatus = AccountDeletionStatus.none
    public var selectedHousehold: HouseholdSnapshot? {
        deletionStatus.blocksAccountUse ? nil : state?.session?.household
    }

    private let api: AccountAPI
    private let shoppingAPI: ShoppingAPI
    private let ledgerAPI: LedgerAPI
    private let householdAccessAPI: HouseholdAccessAPI
    private let notificationAPI: NotificationAPI
    private let analyticsAPI: AnalyticsAPI
    private let tokenStore: any SessionTokenStore
    private var stateToken: SessionToken?

    public init(
        configuration: APIConfiguration,
        tokenStore: any SessionTokenStore,
        transport: (any HTTPTransport)? = nil
    ) {
        let client = NativeAPIClient(
            configuration: configuration, transport: transport ?? URLSessionTransport(configuration: configuration)
        )
        api = AccountAPI(client: client)
        shoppingAPI = ShoppingAPI(client: client)
        ledgerAPI = LedgerAPI(client: client)
        householdAccessAPI = HouseholdAccessAPI(client: client)
        notificationAPI = NotificationAPI(client: client)
        analyticsAPI = AnalyticsAPI(client: client)
        self.tokenStore = tokenStore
    }

    @discardableResult
    public func restore() async throws -> AccountState {
        try beginOperation(allowDeletion: true)
        defer { isBusy = false }
        let token = try await readCredential()
        let previousDeletion = deletionStatus
        do {
            let response = try await api.restore(token: token)
            if !response.isSignedIn, token != nil {
                if previousDeletion != .none {
                    try await clearCredential(matching: token)
                } else {
                    try await clearCredential()
                }
            }
            // A native signed-in response without a stored bearer cannot establish a session.
            guard !response.isSignedIn || token != nil else { throw AccountError.invalidResponse }
            state = response
            stateToken = response.isSignedIn ? token : nil
            deletionStatus = response.deletionPending ? .pending
                : previousDeletion.serverConfirmed && !response.isSignedIn ? .completed : .none
            return response
        } catch {
            try await handleConfirmedExpiry(error)
            throw error
        }
    }

    public func sendEmailCode(email: String) async throws {
        try beginOperation()
        defer { isBusy = false }
        try await api.sendEmailCode(email: email)
    }

    @discardableResult
    public func verifyEmailCode(
        email: String, code: String, name: String, deviceLabel: String
    ) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        let token = try await readCredential()
        let response = try await api.verifyEmailCode(
            email: email, code: code, name: name, deviceLabel: deviceLabel, token: token
        )
        try await saveCredential(response.token)
        state = response.state
        stateToken = response.token
        deletionStatus = .none
        return response.state
    }

    @discardableResult
    public func recover(
        email: String, recoveryCode: String, deviceLabel: String
    ) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        let token = try await readCredential()
        let response = try await api.recover(
            email: email, recoveryCode: recoveryCode, deviceLabel: deviceLabel, token: token
        )
        try await saveCredential(response.token)
        state = response.state
        stateToken = response.token
        deletionStatus = .none
        return response.state
    }

    @discardableResult
    public func logout(allDevices: Bool = false) async throws -> AccountState {
        try beginOperation(allowDeletion: true)
        defer { isBusy = false }
        let token = try await readCredential()
        do {
            let response = try await api.logout(allDevices: allDevices, token: token)
            try await clearCredential()
            state = response
            stateToken = nil
            deletionStatus = .none
            return response
        } catch {
            try await handleConfirmedExpiry(error)
            throw error
        }
    }

    @discardableResult
    public func reauthenticate(accountID: UUID, code: String, deviceLabel: String) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        guard let original = state, let account = original.account, account.id == accountID,
              !original.deletionPending else { throw AccountError.accountStateRequired }
        let stored = try await readCredential()
        try Task.checkCancellation()
        guard let token = stored, token == stateToken else { throw AccountError.accountStateRequired }
        let response = try await api.verifyEmailCode(
            email: account.email, code: code, name: account.name, deviceLabel: deviceLabel, token: token
        )
        try Task.checkCancellation()
        guard response.state.account?.id == accountID, response.state.account?.email == account.email,
              !response.state.deletionPending else { throw AccountError.invalidResponse }
        try await confirmAccountIdentity(original, token: token)
        try Task.checkCancellation()
        try await saveCredential(response.token)
        state = response.state
        stateToken = response.token
        return response.state
    }

    @discardableResult
    public func deleteAccount(accountID: UUID, confirmation: String) async throws -> AccountState {
        try beginOperation(allowDeletion: true)
        defer { isBusy = false }
        guard deletionStatus != .unconfirmed, deletionStatus != .localCleanupRequired,
              let account = state?.account, account.id == accountID else {
            throw AccountError.accountStateRequired
        }
        // Destructive confirmation is deliberately not trimmed or case-normalized.
        guard confirmation == account.email, AccountValidation.email(confirmation) == confirmation else {
            throw AccountError.invalidInput(.confirmation)
        }
        let stored = try await readCredential()
        try Task.checkCancellation()
        guard let token = stored, token == stateToken else { throw AccountError.accountStateRequired }
        deletionStatus = .unconfirmed
        do {
            let response = try await api.deleteAccount(confirmation: confirmation, token: token)
            state = response
            deletionStatus = .localCleanupRequired
            try Task.checkCancellation()
            try await clearCredential(matching: token)
            stateToken = nil
            deletionStatus = .completed
            return response
        } catch {
            if !deletionStatus.serverConfirmed {
                if case AccountError.server(_, .some(.accountDeletionPending)) = error {
                    deletionStatus = .pending
                } else if case AccountError.server(let status, _) = error, (400..<500).contains(status) {
                    deletionStatus = .none
                    if error as? AccountError == .server(status: 401, code: .accountSessionRequired) {
                        // Lost access is not proof that the account was deleted.
                        deletionStatus = .unconfirmed
                        try await clearCredential(matching: token)
                        state = nil
                        stateToken = nil
                    }
                }
            }
            throw error
        }
    }

    @discardableResult
    public func finishAccountDeletionCleanup() async throws -> AccountState {
        try beginOperation(allowDeletion: true)
        defer { isBusy = false }
        guard deletionStatus == .localCleanupRequired, let state, !state.isSignedIn else {
            throw AccountError.accountStateRequired
        }
        try await clearCredential(matching: stateToken)
        stateToken = nil
        deletionStatus = .completed
        return state
    }

    @discardableResult
    public func createHousehold(
        name: String, memberName: String, currency: HouseholdCurrency, budgetCents: Int64, requestID: UUID
    ) async throws -> AccountState {
        try await mutateHousehold { [api] token in
            try await api.createHousehold(
                name: name, memberName: memberName, currency: currency, budgetCents: budgetCents,
                requestID: requestID, token: token
            )
        }
    }

    @discardableResult
    public func acceptInvitation(code: String, memberName: String) async throws -> AccountState {
        try await mutateHousehold { [api] token in
            try await api.acceptInvitation(code: code, memberName: memberName, token: token)
        }
    }

    @discardableResult
    public func selectHousehold(id: UUID) async throws -> AccountState {
        try await mutateHousehold { [api] token in
            try await api.selectHousehold(id: id, token: token)
        }
    }

    public func loadInvitations(householdID: UUID) async throws -> HouseholdInvitationAccess {
        try await loadHouseholdAccess(householdID: householdID)
    }

    public func loadHouseholdAccess(householdID: UUID) async throws -> HouseholdInvitationAccess {
        try await withHouseholdAccess(householdID: householdID) { [householdAccessAPI] token, _ in
            try await householdAccessAPI.load(householdID: householdID, token: token)
        }
    }

    public func createInvitation(householdID: UUID, version: Int64) async throws -> CreatedHouseholdInvitation {
        try await withHouseholdAccess(householdID: householdID) { [householdAccessAPI] token, _ in
            try await householdAccessAPI.create(householdID: householdID, version: version, token: token)
        }
    }

    public func revokeInvitation(id: UUID, householdID: UUID, version: Int64) async throws -> HouseholdInvitationAccess {
        try await withHouseholdAccess(householdID: householdID) { [householdAccessAPI] token, _ in
            try await householdAccessAPI.revoke(id: id, householdID: householdID, version: version, token: token)
        }
    }

    public func transferOwnership(
        to memberID: UUID, householdID: UUID, version: Int64, accountID: UUID
    ) async throws -> HouseholdInvitationAccess {
        try await withHouseholdAccess(householdID: householdID) { [householdAccessAPI] token, original in
            guard original.account?.id == accountID, let selected = original.session,
                  original.memberships.contains(where: { $0.householdID == householdID && $0.role == .owner }) else {
                throw AccountError.accountStateRequired
            }
            guard selected.household.version == version else { throw AccountError.invalidInput(.version) }
            guard selected.memberID != memberID,
                  try HouseholdMember.projection(selected.household.value).contains(where: { $0.id == memberID && !$0.inactive }) else {
                throw AccountError.invalidInput(.memberID)
            }
            return try await householdAccessAPI.transferOwnership(
                to: memberID, householdID: householdID, version: version, token: token
            )
        }
    }

    public func loadNotificationSettings(householdID: UUID) async throws -> HouseholdNotificationSettings {
        try await withNotificationAccount(householdID: householdID) { [notificationAPI] token, memberID in
            guard let memberID else { throw AccountError.accountStateRequired }
            return try await notificationAPI.load(householdID: householdID, memberID: memberID, token: token)
        }
    }

    public func saveNotificationSettings(
        _ preferences: NotificationPreferences, householdID: UUID
    ) async throws -> HouseholdNotificationSettings {
        try await withNotificationAccount(householdID: householdID) { [notificationAPI] token, memberID in
            guard let memberID else { throw AccountError.accountStateRequired }
            return try await notificationAPI.save(preferences, householdID: householdID, memberID: memberID, token: token)
        }
    }

    public func registerPushDevice(installationID: UUID, token: APNsDeviceToken, environment: APNsEnvironment) async throws {
        try await withNotificationAccount { [notificationAPI] credential, _ in
            try await notificationAPI.register(
                installationID: installationID, token: token, environment: environment, credential: credential
            )
        }
    }

    public func unregisterPushDevice(installationID: UUID) async throws {
        try await withNotificationAccount { [notificationAPI] token, _ in
            try await notificationAPI.unregister(installationID: installationID, token: token)
        }
    }

    /// Telemetry must not acquire the account mutation gate or change state/credentials,
    /// including when an expired request finishes after a new sign-in.
    public func recordAnalytics(_ event: AnalyticsEvent, context: AnalyticsContext) async throws {
        try Task.checkCancellation()
        try requireAnalyticsContext(context)
        let stored = try await readCredential()
        try Task.checkCancellation()
        try requireAnalyticsContext(context)
        guard let token = stored, token == stateToken else { throw AccountError.accountStateRequired }
        try await analyticsAPI.record(event, householdID: context.householdID, token: token)
        try Task.checkCancellation()
        try requireAnalyticsContext(context)
        guard stateToken == token else { throw AccountError.accountStateRequired }
    }

    private func requireAnalyticsContext(_ expected: AnalyticsContext) throws {
        guard !deletionStatus.blocksAccountUse, let state, try AnalyticsContext(state: state) == expected else {
            throw AccountError.accountStateRequired
        }
    }

    @discardableResult
    public func addChore(
        _ draft: ChoreDraft, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateSelectedHousehold(householdID: householdID, version: version) { [api] token, _, _ in
            try await api.addChore(draft, version: version, mutationID: mutationID, token: token)
        }
    }

    @discardableResult
    public func completeChore(
        id: UUID, choreVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateSelectedHousehold(householdID: householdID, version: version) { [api] token, _, _ in
            try await api.completeChore(
                id: id, choreVersion: choreVersion, version: version, mutationID: mutationID, token: token
            )
        }
    }

    @discardableResult
    public func undoChoreCompletion(
        id: UUID, choreVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateSelectedHousehold(householdID: householdID, version: version) { [api] token, memberID, _ in
            try await api.undoChoreCompletion(
                id: id, choreVersion: choreVersion, version: version, mutationID: mutationID, memberID: memberID, token: token
            )
        }
    }

    @discardableResult
    public func addShoppingItem(
        _ draft: ShoppingDraft, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateShopping(.add(draft), householdID: householdID, version: version, mutationID: mutationID)
    }

    @discardableResult
    public func editShoppingItem(
        id: UUID, draft: ShoppingDraft, itemVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateShopping(
            .edit(id, draft, itemVersion), householdID: householdID, version: version, mutationID: mutationID
        )
    }

    @discardableResult
    public func removeShoppingItem(
        id: UUID, itemVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateShopping(.remove(id, itemVersion), householdID: householdID, version: version, mutationID: mutationID)
    }

    @discardableResult
    public func claimShoppingItem(
        id: UUID, claim: Bool, itemVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateShopping(
            .claim(id, claim, itemVersion), householdID: householdID, version: version, mutationID: mutationID
        )
    }

    @discardableResult
    public func pickShoppingItem(
        id: UUID, pickedUp: Bool, itemVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateShopping(
            .pick(id, pickedUp, itemVersion), householdID: householdID, version: version, mutationID: mutationID
        )
    }

    private func mutateShopping(
        _ change: ShoppingChange, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateSelectedHousehold(householdID: householdID, version: version) { [shoppingAPI] token, memberID, shopping in
            try await shoppingAPI.mutate(
                change, version: version, mutationID: mutationID, memberID: memberID, shopping: shopping, token: token
            )
        }
    }

    @discardableResult
    public func recordExpense(
        _ draft: ExpenseDraft, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateLedger(.record(draft), householdID: householdID, version: version, mutationID: mutationID)
    }

    @discardableResult
    public func checkoutShopping(
        _ draft: ExpenseDraft, checkoutID: UUID, selection: [ShoppingSelection],
        householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateLedger(
            .checkout(draft, checkoutID, selection), householdID: householdID, version: version, mutationID: mutationID
        )
    }

    @discardableResult
    public func removeExpense(
        id: UUID, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateLedger(.remove(id), householdID: householdID, version: version, mutationID: mutationID)
    }

    @discardableResult
    public func recordSettlement(
        from: UUID, to: UUID, amount: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateLedger(
            .settle(from: from, to: to, amount: amount), householdID: householdID, version: version, mutationID: mutationID
        )
    }

    @discardableResult
    public func removeSettlement(
        id: UUID, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateLedger(.removeSettlement(id), householdID: householdID, version: version, mutationID: mutationID)
    }

    private func mutateLedger(
        _ change: LedgerChange, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateSelectedHousehold(householdID: householdID, version: version) { [ledgerAPI] token, memberID, ledger in
            try await ledgerAPI.mutate(
                change, version: version, mutationID: mutationID, memberID: memberID, ledger: ledger, token: token
            )
        }
    }

    private func mutateSelectedHousehold<Projection: HouseholdProjection>(
        householdID: UUID, version: Int64,
        _ operation: @Sendable (SessionToken, UUID, Projection) async throws -> HouseholdMutationResponse<Projection>
    ) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        guard let original = state, original.isSignedIn, !original.deletionPending,
              let selected = original.session else { throw AccountError.accountStateRequired }
        guard selected.household.id == householdID else { throw AccountError.householdSelectionChanged }
        let storedToken = try await readCredential()
        try Task.checkCancellation()
        guard let token = storedToken, token == stateToken else { throw AccountError.accountStateRequired }
        let projection = try Projection(household: selected.household)
        guard projection.activeMembers.contains(where: { $0.id == selected.memberID }) else {
            throw AccountError.accountStateRequired
        }
        do {
            let response = try await operation(token, selected.memberID, projection)
            try Task.checkCancellation()
            guard state == original, stateToken == token,
                  response.household.id == householdID,
                  response.household.version >= selected.household.version,
                  response.household.version > version,
                  response.replayed || response.household.version == version + 1,
                  response.projection.activeMembers.contains(where: { $0.id == selected.memberID }) else {
                throw AccountError.invalidResponse
            }
            let updated = try original.replacingHousehold(response.household)
            state = updated
            return updated
        } catch {
            try await handleConfirmedExpiry(error)
            throw error
        }
    }

    private func withHouseholdAccess<Response: HouseholdAccessResponse>(
        householdID: UUID, _ operation: @Sendable (SessionToken, AccountState) async throws -> Response
    ) async throws -> Response {
        try beginOperation()
        defer { isBusy = false }
        guard let original = state, original.isSignedIn, !original.deletionPending,
              let selected = original.session else { throw AccountError.accountStateRequired }
        guard selected.household.id == householdID else { throw AccountError.householdSelectionChanged }
        guard try !selected.viewer.inactive else { throw AccountError.accountStateRequired }
        let stored = try await readCredential()
        try Task.checkCancellation()
        guard let token = stored, token == stateToken else { throw AccountError.accountStateRequired }
        do {
            let response = try await operation(token, original)
            try Task.checkCancellation()
            let access = response.access
            guard state == original, stateToken == token, access.household.id == householdID,
                  access.memberID == selected.memberID,
                  access.household.version >= selected.household.version else {
                throw AccountError.invalidResponse
            }
            try await confirmAccountIdentity(original, token: token)
            try Task.checkCancellation()
            state = try original.replacingHousehold(access.household, role: access.role)
            return response
        } catch {
            if error as? AccountError == .server(status: 401, code: .accountSessionRequired) {
                try await confirmAccountIdentity(original, token: token)
                try await handleConfirmedExpiry(error)
            }
            throw error
        }
    }

    private func withNotificationAccount<Response: Sendable>(
        householdID: UUID? = nil,
        _ operation: @Sendable (SessionToken, UUID?) async throws -> Response
    ) async throws -> Response {
        try beginOperation()
        defer { isBusy = false }
        guard let original = state, original.isSignedIn, !original.deletionPending else {
            throw AccountError.accountStateRequired
        }
        var memberID: UUID?
        if let householdID {
            guard let selected = original.session else { throw AccountError.accountStateRequired }
            guard selected.household.id == householdID else { throw AccountError.householdSelectionChanged }
            guard try !selected.viewer.inactive else { throw AccountError.accountStateRequired }
            memberID = selected.memberID
        }
        let stored = try await readCredential()
        try Task.checkCancellation()
        guard let token = stored, token == stateToken, state == original else {
            throw AccountError.accountStateRequired
        }
        do {
            let response = try await operation(token, memberID)
            try Task.checkCancellation()
            try await confirmAccountIdentity(original, token: token)
            try Task.checkCancellation()
            return response
        } catch {
            if error as? AccountError == .server(status: 401, code: .accountSessionRequired) {
                try await confirmAccountIdentity(original, token: token)
                try await handleConfirmedExpiry(error)
            }
            throw error
        }
    }

    private func confirmAccountIdentity(_ original: AccountState, token: SessionToken) async throws {
        let stored = try await readCredential()
        guard state == original, stateToken == token else { throw AccountError.invalidResponse }
        guard stored == token else { throw AccountError.accountStateRequired }
    }

    private func mutateHousehold(
        _ operation: @Sendable (SessionToken?) async throws -> AccountState
    ) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        let token = try await readCredential()
        do {
            let response = try await operation(token)
            guard token != nil, response.isSignedIn else { throw AccountError.invalidResponse }
            state = response
            stateToken = token
            return response
        } catch {
            try await handleConfirmedExpiry(error)
            throw error
        }
    }

    private func beginOperation(allowDeletion: Bool = false) throws {
        guard !isBusy else { throw AccountError.operationInProgress }
        try Task.checkCancellation()
        guard allowDeletion || !deletionStatus.blocksAccountUse else { throw AccountError.accountStateRequired }
        isBusy = true
    }

    private func handleConfirmedExpiry(_ error: any Error) async throws {
        guard let error = error as? AccountError,
              case .server(status: 401, code: .some(.accountSessionRequired)) = error else { return }
        try await clearCredential()
        state = nil
        stateToken = nil
        deletionStatus = deletionStatus.serverConfirmed ? .completed : .none
    }

    private func readCredential() async throws -> SessionToken? {
        do {
            return try await tokenStore.read()
        } catch let error as KeychainError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.credentialStorage
        }
    }

    private func saveCredential(_ token: SessionToken) async throws {
        do {
            try await tokenStore.save(token)
        } catch let error as KeychainError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.credentialStorage
        }
    }

    private func clearCredential() async throws {
        do {
            try await tokenStore.clear()
        } catch let error as KeychainError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.credentialStorage
        }

    }

    private func clearCredential(matching expected: SessionToken?) async throws {
        let stored = try await readCredential()
        try Task.checkCancellation()
        guard stored == nil || stored == expected else { throw AccountError.accountStateRequired }
        try await clearCredential()
    }
}
