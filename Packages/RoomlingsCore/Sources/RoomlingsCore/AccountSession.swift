import Foundation

/// Own one coordinator per Keychain entry. Overlapping operations fail rather than race token writes.
public actor AccountSession {
    public private(set) var state: AccountState?
    public private(set) var isBusy = false
    public var selectedHousehold: HouseholdSnapshot? { state?.session?.household }

    private let api: AccountAPI
    private let tokenStore: any SessionTokenStore
    private var stateToken: SessionToken?

    public init(
        configuration: APIConfiguration,
        tokenStore: any SessionTokenStore,
        transport: (any HTTPTransport)? = nil
    ) {
        api = AccountAPI(configuration: configuration, transport: transport ?? URLSessionTransport(configuration: configuration))
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
        try await mutateChores(householdID: householdID, version: version) { [api] token, _ in
            try await api.addChore(draft, version: version, mutationID: mutationID, token: token)
        }
    }

    @discardableResult
    public func completeChore(
        id: UUID, choreVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateChores(householdID: householdID, version: version) { [api] token, _ in
            try await api.completeChore(
                id: id, choreVersion: choreVersion, version: version, mutationID: mutationID, token: token
            )
        }
    }

    @discardableResult
    public func undoChoreCompletion(
        id: UUID, choreVersion: Int64, householdID: UUID, version: Int64, mutationID: UUID
    ) async throws -> AccountState {
        try await mutateChores(householdID: householdID, version: version) { [api] token, memberID in
            try await api.undoChoreCompletion(
                id: id, choreVersion: choreVersion, version: version, mutationID: mutationID, memberID: memberID, token: token
            )
        }
    }

    private func mutateChores(
        householdID: UUID, version: Int64,
        _ operation: @Sendable (SessionToken, UUID) async throws -> ChoreMutationResponse
    ) async throws -> AccountState {
        try beginOperation()
        defer { isBusy = false }
        guard let original = state, original.isSignedIn, !original.deletionPending,
              let selected = original.session else { throw AccountError.accountStateRequired }
        guard selected.household.id == householdID else { throw AccountError.householdSelectionChanged }
        let storedToken = try await readCredential()
        guard let token = storedToken, token == stateToken else { throw AccountError.accountStateRequired }
        let chores = try HouseholdChores(household: selected.household)
        guard chores.activeMembers.contains(where: { $0.id == selected.memberID }) else {
            throw AccountError.accountStateRequired
        }
        do {
            let response = try await operation(token, selected.memberID)
            try Task.checkCancellation()
            guard state == original, stateToken == token,
                  response.household.id == householdID,
                  response.household.version >= selected.household.version,
                  response.household.version > version,
                  response.replayed || response.household.version == version + 1,
                  response.chores.activeMembers.contains(where: { $0.id == selected.memberID }) else {
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
