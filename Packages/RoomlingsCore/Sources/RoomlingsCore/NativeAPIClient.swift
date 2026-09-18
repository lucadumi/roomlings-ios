import Foundation

struct NativeAPIClient: Sendable {
    let configuration: APIConfiguration
    let transport: any HTTPTransport

    func mutation<Response: Decodable & Sendable>(
        _ endpoint: APIEndpoint, fields: [String: JSONValue],
        version: Int64, mutationID: UUID, token: SessionToken
    ) async throws -> Response {
        guard (0..<HouseholdValidation.maximumInteger).contains(version) else {
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

    func request<Response: Decodable & Sendable>(
        _ endpoint: APIEndpoint, body: Data? = nil, token: SessionToken? = nil
    ) async throws -> Response {
        var request = URLRequest(
            url: configuration.url(for: endpoint),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = endpoint.method
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
}

private struct ServerErrorEnvelope: Decodable { let error: String; let code: String? }
