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
