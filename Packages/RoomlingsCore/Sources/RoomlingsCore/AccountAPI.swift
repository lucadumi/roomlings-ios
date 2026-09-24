import Foundation

struct AccountAPI: Sendable {
    let client: NativeAPIClient

    func sendEmailCode(email: String) async throws {
        let payload = EmailCodeRequest(email: try emailInput(email))
        let response: CodeSentResponse = try await client.request(.code, body: JSONEncoder().encode(payload))
        guard response.sent else { throw AccountError.invalidResponse }
    }

    func restore(token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await client.request(.account, token: token)
        return response.state
    }

    func verifyEmailCode(
        email: String, code: String, name: String, deviceLabel: String, token: SessionToken?
    ) async throws -> NativeSignInResponse {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountValidation.matches(code, #"^[0-9]{6,10}$"#) else {
            throw AccountError.invalidInput(.emailCode)
        }
        let payload = VerifyCodeRequest(
            email: try emailInput(email), code: code,
            name: try nameInput(name, field: .name),
            label: try nameInput(deviceLabel, field: .deviceLabel)
        )
        return try await client.request(.verify, body: JSONEncoder().encode(payload), token: token)
    }

    func recover(
        email: String, recoveryCode: String, deviceLabel: String, token: SessionToken?
    ) async throws -> NativeSignInResponse {
        let code = recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AccountValidation.matches(code, #"^roomlings-account-[a-f0-9]{4}(?:-[a-f0-9]{4}){7}$"#) else {
            throw AccountError.invalidInput(.recoveryCode)
        }
        let payload = RecoveryRequest(
            email: try emailInput(email), code: code, label: try nameInput(deviceLabel, field: .deviceLabel)
        )
        return try await client.request(.recover, body: JSONEncoder().encode(payload), token: token)
    }

    func logout(allDevices: Bool, token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await client.request(
            .logout, body: JSONEncoder().encode(LogoutRequest(all: allDevices)), token: token
        )
        guard !response.state.isSignedIn else { throw AccountError.invalidResponse }
        return response.state
    }

    func deleteAccount(confirmation: String, token: SessionToken) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await client.request(
            .deleteAccount, body: JSONEncoder().encode(DeleteAccountRequest(confirmation: confirmation)), token: token
        )
        guard !response.state.isSignedIn else { throw AccountError.invalidResponse }
        return response.state
    }

    func createHousehold(
        name: String, memberName: String, currency: HouseholdCurrency, budgetCents: Int64,
        requestID: UUID, token: SessionToken?
    ) async throws -> AccountState {
        guard (1...100_000_000).contains(budgetCents) else { throw AccountError.invalidInput(.budgetCents) }
        let payload = CreateHouseholdRequest(
            name: try nameInput(name, field: .name),
            memberName: try nameInput(memberName, field: .memberName),
            currency: currency, budget: budgetCents, requestId: requestID.uuidString.lowercased()
        )
        let response: OrdinaryAccountResponse = try await client.request(
            .createHousehold, body: JSONEncoder().encode(payload), token: token
        )
        return response.state
    }

    func acceptInvitation(code: String, memberName: String, token: SessionToken?) async throws -> AccountState {
        let payload = AcceptInvitationRequest(
            code: try AccountInvitationCode(code).value, memberName: try nameInput(memberName, field: .memberName)
        )
        let response: OrdinaryAccountResponse = try await client.request(
            .acceptInvitation, body: JSONEncoder().encode(payload), token: token
        )
        return response.state
    }

    func selectHousehold(id: UUID, token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await client.request(
            .selectHousehold(id), body: Data("{}".utf8), token: token
        )
        return response.state
    }

    func addChore(
        _ draft: ChoreDraft, version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        try await client.mutation(
            .addChore, fields: draft.requestFields, version: version, mutationID: mutationID, token: token
        )
    }

    func completeChore(
        id: UUID, choreVersion: Int64, version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        guard (0..<ChoreValidation.maximumInteger).contains(choreVersion) else {
            throw AccountError.invalidInput(.choreVersion)
        }
        let response: ChoreMutationResponse = try await client.mutation(
            .completeChore(id), fields: ["choreVersion": .integer(choreVersion)],
            version: version, mutationID: mutationID, token: token
        )
        guard let chore = response.projection.items.first(where: { $0.id == id }),
              chore.version > choreVersion,
              response.replayed || chore.version == choreVersion + 1 else {
            throw AccountError.invalidResponse
        }
        return response
    }

    func undoChoreCompletion(
        id: UUID, choreVersion: Int64, version: Int64, mutationID: UUID, memberID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        guard (0..<ChoreValidation.maximumInteger).contains(choreVersion) else {
            throw AccountError.invalidInput(.choreVersion)
        }
        let response: ChoreMutationResponse = try await client.mutation(
            .undoChoreCompletion(id), fields: ["choreVersion": .integer(choreVersion)],
            version: version, mutationID: mutationID, token: token
        )
        guard let completion = response.projection.history.first(where: { $0.id == id }),
              completion.resultVersion == choreVersion, completion.undoneAt != nil,
              completion.undoneBy == memberID,
              let chore = response.projection.items.first(where: { $0.id == completion.choreID }),
              chore.version > choreVersion,
              response.replayed || (chore.version == choreVersion + 1 && !chore.archived
                && chore.occurrence == completion.occurrence && chore.dueDate == completion.dueDate
                && chore.turn == completion.turn && chore.updatedAt == completion.undoneAt) else {
            throw AccountError.invalidResponse
        }
        return response
    }

    private func emailInput(_ email: String) throws -> String {
        guard let email = AccountValidation.email(email) else { throw AccountError.invalidInput(.email) }
        return email
    }

    private func nameInput(_ name: String, field: AccountInputField) throws -> String {
        guard let name = AccountValidation.name(name) else { throw AccountError.invalidInput(field) }
        return name
    }
}

struct NativeSignInResponse: Decodable, Sendable {
    let state: AccountState
    let token: SessionToken

    private enum CodingKeys: String, CodingKey { case accessToken }

    init(from decoder: any Decoder) throws {
        state = try AccountState(from: decoder)
        guard state.isSignedIn else { throw AccountError.invalidResponse }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try SessionToken(container.decode(String.self, forKey: .accessToken))
    }
}

struct OrdinaryAccountResponse: Decodable, Sendable {
    let state: AccountState

    private enum CodingKeys: String, CodingKey { case accessToken }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        state = try AccountState(from: decoder)
    }
}

private struct CodeSentResponse: Decodable, Sendable { let sent: Bool }
private struct EmailCodeRequest: Encodable { let email: String }
private struct VerifyCodeRequest: Encodable { let email: String; let code: String; let name: String; let label: String }
private struct RecoveryRequest: Encodable { let email: String; let code: String; let label: String }
private struct LogoutRequest: Encodable { let all: Bool }
private struct DeleteAccountRequest: Encodable { let confirmation: String }
private struct CreateHouseholdRequest: Encodable {
    let name: String
    let memberName: String
    let currency: HouseholdCurrency
    let budget: Int64
    let requestId: String
}
private struct AcceptInvitationRequest: Encodable { let code: String; let memberName: String }
