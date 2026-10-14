import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Room admins", .timeLimit(.minutes(1)))
struct RoomAdminsTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let mutationID = ShoppingFixtures.mutationID
    private let roommate = ShoppingFixtures.roommateID

    @Test
    func grantingSendsOnlyTheRoleForThatRoommate() async throws {
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.household(version: 18))
        let (session, transport) = try await make(response: try Fixtures.response(["household": saved]))
        try await session.setRoomRole(memberID: roommate, role: .admin, householdID: householdID, version: 17, mutationID: mutationID)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/household/room-access/\(roommate.uuidString.lowercased())")
        #expect(try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) == .object([
            "role": .string("admin"), "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": .string(mutationID.uuidString.lowercased()),
        ]))
        #expect(await session.state?.session?.household.version == 18)
    }

    @Test
    func ownershipAndFormerRoommatesCannotBeChangedHere() async throws {
        let (session, transport) = try await make(response: try Fixtures.failure(status: 500, code: nil))
        await #expect(throws: AccountError.invalidInput(.memberID)) {
            try await session.setRoomRole(memberID: roommate, role: .owner, householdID: householdID, version: 17, mutationID: mutationID)
        }
        await #expect(throws: AccountError.invalidInput(.memberID)) {
            try await session.setRoomRole(memberID: ShoppingFixtures.inactiveID, role: .admin, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func aResponseThatChangesHouseholdDataIsRejected() async throws {
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(ShoppingFixtures.household(version: 18), with: ["name": .string("Elsewhere")]))
        let (session, _) = try await make(response: try Fixtures.response(["household": saved]))
        await #expect(throws: AccountError.invalidResponse) {
            try await session.setRoomRole(memberID: roommate, role: .member, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await session.state?.session?.household.version == 17)
    }

    private func make(response: HTTPResponse) async throws -> (AccountSession, TestTransport) {
        let transport = TestTransport(responses: [try Fixtures.response(ShoppingFixtures.state()), response])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        return (session, transport)
    }
}
