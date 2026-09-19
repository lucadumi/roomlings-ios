import Foundation

/// Own one coordinator per Keychain entry. Overlapping operations fail rather than race token writes.
public actor AccountSession {
    public private(set) var state: AccountState?
    public private(set) var isBusy = false
    public var selectedHousehold: HouseholdSnapshot? { state?.session?.household }

    private let api: AccountAPI
    private let shoppingAPI: ShoppingAPI
    private let ledgerAPI: LedgerAPI
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
        self.tokenStore = tokenStore
    }

    @discardableResult
    public func restore() async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        let token = try await readCredential()
        do {
            let response = try await api.restore(token: token)
            if !response.isSignedIn, token != nil { try await clearCredential() }
            // A native signed-in response without a stored bearer cannot establish a session.
            guard !response.isSignedIn || token != nil else { throw AccountError.invalidResponse }
            state = response
            stateToken = response.isSignedIn ? token : nil
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
        return response.state
    }

    @discardableResult
    public func logout(allDevices: Bool = false) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        let token = try await readCredential()
        do {
            let response = try await api.logout(allDevices: allDevices, token: token)
            try await clearCredential()
            state = response
            stateToken = nil
            return response
        } catch {
            try await handleConfirmedExpiry(error)
            throw error
        }
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

    private func beginOperation() throws {
        guard !isBusy else { throw AccountError.operationInProgress }
        try Task.checkCancellation()
        isBusy = true
    }

    private func handleConfirmedExpiry(_ error: any Error) async throws {
        guard let error = error as? AccountError,
              case .server(status: 401, code: .some(.accountSessionRequired)) = error else { return }
        try await clearCredential()
        state = nil
        stateToken = nil
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
}
