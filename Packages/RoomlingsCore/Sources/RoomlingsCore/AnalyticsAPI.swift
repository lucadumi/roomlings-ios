import Foundation

struct AnalyticsAPI: Sendable {
    let client: NativeAPIClient

    func record(_ event: AnalyticsEvent, householdID: UUID, token: SessionToken) async throws {
        let _: AnalyticsAcknowledgment = try await client.request(
            .recordAnalytics(householdID), body: JSONEncoder().encode(["events": [event]]), token: token
        )
    }
}

private struct AnalyticsAcknowledgment: Decodable, Sendable {
    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let fields) = value, Set(fields.keys) == ["recorded"],
              fields["recorded"]?.integerValue == 1 else { throw AccountError.invalidResponse }
    }
}
