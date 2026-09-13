import Foundation

/// Own one coordinator per Keychain entry. Overlapping operations fail rather than race token writes.
public actor AccountSession {
    public private(set) var state: AccountState?
    public private(set) var isBusy = false
    public var selectedHousehold: HouseholdSnapshot? { state?.session?.household }

    private let api: AccountAPI
    private let tokenStore: any SessionTokenStore

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
