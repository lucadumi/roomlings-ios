import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Room style", .timeLimit(.minutes(1)))
struct HouseholdRoomStyleTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let mutationID = ShoppingFixtures.mutationID

    @Test
    func applyingSendsOnlyTheStyleAndKeepsEverythingElse() async throws {
        let original = household(style: "clay")
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(original, with: [
            "roomStyle": .string("coastal"), "version": .integer(18),
        ]))
        let (session, transport) = try await make(initial: original, response: .success(saved))
        let result = try await session.updateRoomStyle("coastal", householdID: householdID, version: 17, mutationID: mutationID)

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/household/room-style")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "roomStyle": .string("coastal"), "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": .string(mutationID.uuidString.lowercased()),
        ]))
        #expect(try HouseholdRoomStyle(household: #require(result.session?.household)).style == "coastal")
    }

    @Test
    func aMissingStyleMeansTheOriginalLook() throws {
        let plain = ShoppingFixtures.household()
        #expect(try HouseholdRoomStyle(household: ShoppingFixtures.snapshot(plain)).style == "original")
        let broken = ShoppingFixtures.replacing(plain, with: ["roomStyle": .integer(3)])
        #expect(throws: AccountError.invalidResponse) { try HouseholdRoomStyle(household: ShoppingFixtures.snapshot(broken)) }
    }

    @Test
    func aResponseThatChangesAnythingElseIsRejected() async throws {
        let original = household(style: "clay")
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(original, with: [
            "roomStyle": .string("coastal"), "version": .integer(18), "budget": .integer(1),
        ]))
        let (session, _) = try await make(initial: original, response: .success(saved))
        await #expect(throws: AccountError.invalidResponse) {
            try await session.updateRoomStyle("coastal", householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await session.state?.session?.household.value["roomStyle"] == .string("clay"))
    }

    @Test
    func aMemberWithoutRoomAccessIsRefusedOnceAndNotRetried() async throws {
        let (session, transport) = try await make(initial: household(style: "clay"), response: .failure(403))
        await #expect(throws: AccountError.server(status: 403, code: nil)) {
            try await session.updateRoomStyle("coastal", householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func malformedStylesNeverReachTheServer() async throws {
        let (session, transport) = try await make(initial: household(style: "clay"), response: .failure(500))
        for style in ["", "Coastal", "sea-green", String(repeating: "a", count: 33)] {
            await #expect(throws: AccountError.invalidInput(.roomStyle)) {
                try await session.updateRoomStyle(style, householdID: householdID, version: 17, mutationID: mutationID)
            }
        }
        #expect(await transport.requests.count == 1)
    }

    // MARK: - Fixtures

    private enum Reply {
        case success(JSONValue), failure(Int)
    }

    private func household(style: String) -> JSONValue {
        ShoppingFixtures.replacing(ShoppingFixtures.household(), with: ["roomStyle": .string(style)])
    }

    private func make(initial: JSONValue, response: Reply) async throws -> (AccountSession, TestTransport) {
        let reply: HTTPResponse
        switch response {
        case .success(let household): reply = try Fixtures.response(["household": household], path: "api/household/room-style")
        case .failure(let status): reply = try Fixtures.failure(status: status, code: nil)
        }
        let transport = TestTransport(responses: [try Fixtures.response(ShoppingFixtures.state(household: initial)), reply])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        return (session, transport)
    }
}
