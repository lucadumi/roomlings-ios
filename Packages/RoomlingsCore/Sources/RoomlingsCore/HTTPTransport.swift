import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let url: URL

    public init(data: Data, statusCode: Int, url: URL) {
        self.data = data
        self.statusCode = statusCode
        self.url = url
    }
}

/// Implementations must not forward requests across redirects or add browser authentication headers.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let configuration: APIConfiguration

    public init(configuration: APIConfiguration) {
        self.configuration = configuration
        session = URLSession(
            configuration: Self.sessionConfiguration(configuration),
            delegate: RejectRedirects(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, configuration.contains(url) else { throw AccountError.untrustedResponse }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw AccountError.invalidResponse
        }
        return HTTPResponse(data: data, statusCode: response.statusCode, url: url)
    }

    static func sessionConfiguration(_ configuration: APIConfiguration) -> URLSessionConfiguration {
        let session = URLSessionConfiguration.ephemeral
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.httpCookieAcceptPolicy = .never
        session.urlCredentialStorage = nil
        session.urlCache = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.timeoutIntervalForRequest = configuration.requestTimeout
        session.timeoutIntervalForResource = configuration.requestTimeout
        session.waitsForConnectivity = false
        return session
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
