import Foundation

struct AccountAPI: Sendable {
    let configuration: APIConfiguration
    let transport: any HTTPTransport

    func sendEmailCode(email: String) async throws {
        let payload = EmailCodeRequest(email: try emailInput(email))
        let response: CodeSentResponse = try await request(.code, body: JSONEncoder().encode(payload))
        guard response.sent else { throw AccountError.invalidResponse }
    }

    func restore(token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await request(.account, token: token)
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
        return try await request(.verify, body: JSONEncoder().encode(payload), token: token)
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
        return try await request(.recover, body: JSONEncoder().encode(payload), token: token)
    }

    func logout(allDevices: Bool, token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await request(
            .logout, body: JSONEncoder().encode(LogoutRequest(all: allDevices)), token: token
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
        let response: OrdinaryAccountResponse = try await request(
            .createHousehold, body: JSONEncoder().encode(payload), token: token
        )
        return response.state
    }

    func acceptInvitation(code: String, memberName: String, token: SessionToken?) async throws -> AccountState {
        let payload = AcceptInvitationRequest(
            code: try invitationInput(code), memberName: try nameInput(memberName, field: .memberName)
        )
        let response: OrdinaryAccountResponse = try await request(
            .acceptInvitation, body: JSONEncoder().encode(payload), token: token
        )
        return response.state
    }

    func selectHousehold(id: UUID, token: SessionToken?) async throws -> AccountState {
        let response: OrdinaryAccountResponse = try await request(
            .selectHousehold(id), body: Data("{}".utf8), token: token
        )
        return response.state
    }

    func addChore(
        _ draft: ChoreDraft, version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        try await choreMutation(
            .addChore, fields: draft.requestFields, version: version, mutationID: mutationID, token: token
        )
    }

    func completeChore(
        id: UUID, choreVersion: Int64, version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        guard (0..<ChoreValidation.maximumInteger).contains(choreVersion) else {
            throw AccountError.invalidInput(.choreVersion)
        }
        let response = try await choreMutation(
            .completeChore(id), fields: ["choreVersion": .integer(choreVersion)],
            version: version, mutationID: mutationID, token: token
        )
        guard let chore = response.chores.items.first(where: { $0.id == id }),
              chore.version > choreVersion,
              response.replayed || chore.version == choreVersion + 1 else {
            throw AccountError.invalidResponse
        }
        return response
    }

    private func choreMutation(
        _ endpoint: AccountEndpoint, fields: [String: JSONValue],
        version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> ChoreMutationResponse {
        guard (0..<ChoreValidation.maximumInteger).contains(version) else {
            throw AccountError.invalidInput(.version)
        }
        var payload = fields
        payload["version"] = .integer(version)
        payload["mutationId"] = .string(mutationID.uuidString.lowercased())
        // Replay lookup precedes version checking. Keep the caller's original version and payload.
        payload["mutationVersion"] = .integer(version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await request(endpoint, body: encoder.encode(JSONValue.object(payload)), token: token)
    }

    private func request<Response: Decodable & Sendable>(
        _ endpoint: AccountEndpoint, body: Data? = nil, token: SessionToken? = nil
    ) async throws -> Response {
        var request = URLRequest(
            url: configuration.url(for: endpoint),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = endpoint == .account ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        request.setValue("ios", forHTTPHeaderField: "X-Roomlings-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization") }

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AccountError.network(code: error.errorCode)
        } catch let error as AccountError {
            throw error
        } catch {
            throw AccountError.network(code: nil)
        }
        guard configuration.contains(response.url) else { throw AccountError.untrustedResponse }
        guard (100...599).contains(response.statusCode) else { throw AccountError.invalidResponse }
        if (300...399).contains(response.statusCode) { throw AccountError.redirectRejected }
        guard (200...299).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: response.data)
            let code = envelope?.code.flatMap(AccountServerCode.init(rawValue:))
            throw AccountError.server(status: response.statusCode, code: code)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AccountError.invalidResponse
        }
    }

    private func emailInput(_ email: String) throws -> String {
        guard let email = AccountValidation.email(email) else { throw AccountError.invalidInput(.email) }
        return email
    }

    private func nameInput(_ name: String, field: AccountInputField) throws -> String {
        guard let name = AccountValidation.name(name) else { throw AccountError.invalidInput(field) }
        return name
    }

    private func invitationInput(_ invitation: String) throws -> String {
        var code = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.contains("://") {
            guard !code.contains("\\"),
                  code.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  let link = URLComponents(string: code),
                  ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
                  link.host?.isEmpty == false, link.url != nil,
                  link.user == nil, link.password == nil,
                  let fragment = link.percentEncodedFragment else {
                throw AccountError.invalidInput(.invitationCode)
            }
            var parameters = URLComponents()
            // Match URLSearchParams form decoding without opening the invitation's URL.
            parameters.percentEncodedQuery = fragment.replacingOccurrences(of: "+", with: "%20")
            let codes = parameters.queryItems?.filter { $0.name == "account-invite" } ?? []
            guard codes.count == 1, let value = codes.first?.value else {
                throw AccountError.invalidInput(.invitationCode)
            }
            code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard AccountValidation.matches(code, #"^roomlings-invite-[A-Za-z0-9_-]{43}$"#) else {
            throw AccountError.invalidInput(.invitationCode)
        }
        return code
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

struct ChoreMutationResponse: Decodable, Sendable {
    let household: HouseholdSnapshot
    let chores: HouseholdChores
    let replayed: Bool

    private enum CodingKeys: String, CodingKey { case household, replayed, accessToken }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        household = try container.decode(HouseholdSnapshot.self, forKey: .household)
        guard household.value["chores"] != nil else { throw AccountError.invalidResponse }
        chores = try HouseholdChores(household: household)
        if container.contains(.replayed) {
            guard try container.decode(Bool.self, forKey: .replayed) else { throw AccountError.invalidResponse }
            replayed = true
        } else {
            replayed = false
        }
    }
}

private struct OrdinaryAccountResponse: Decodable, Sendable {
    let state: AccountState

    private enum CodingKeys: String, CodingKey { case accessToken }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        state = try AccountState(from: decoder)
    }
}

private struct CodeSentResponse: Decodable, Sendable { let sent: Bool }
private struct ServerErrorEnvelope: Decodable { let error: String; let code: String? }
private struct EmailCodeRequest: Encodable { let email: String }
private struct VerifyCodeRequest: Encodable { let email: String; let code: String; let name: String; let label: String }
private struct RecoveryRequest: Encodable { let email: String; let code: String; let label: String }
private struct LogoutRequest: Encodable { let all: Bool }
private struct CreateHouseholdRequest: Encodable {
    let name: String
    let memberName: String
    let currency: HouseholdCurrency
    let budget: Int64
    let requestId: String
}
private struct AcceptInvitationRequest: Encodable { let code: String; let memberName: String }
