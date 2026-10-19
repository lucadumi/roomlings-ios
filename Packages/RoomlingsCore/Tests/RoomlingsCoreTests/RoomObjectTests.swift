import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Room objects", .timeLimit(.minutes(1)))
struct RoomObjectTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let mutationID = ShoppingFixtures.mutationID

    @Test
    func layoutsReadAsTheWebDoes() throws {
        let defaults = try Self.defaults()
        #expect(try RoomObject.list(household: .object([:]), defaults: defaults) == defaults)
        // Retired placements move to Storage, and layouts saved before the living room gain its defaults.
        let saved = try RoomObject.list(household: .object(["roomComponents": .array([
            Self.object("bread", kind: "bread-box", slot: "kitchen-table-top"), Self.sink,
        ])]), defaults: defaults)
        #expect(saved.map(\.id) == ["bread", "default-kitchen-sink", "default-living-room-sofa"])
        #expect(saved.map(\.installed) == [false, true, true])
        #expect(throws: AccountError.invalidResponse) {
            try RoomObject.list(household: .object(["roomComponents": .array([Self.sink, Self.sink])]), defaults: defaults)
        }
    }

    @Test
    func settingAStateSendsOnlyTheStateAndAcceptsTheServersLayout() async throws {
        let defaults = try Self.defaults()
        // A household that never saved a layout comes back with the defaults written out.
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(ShoppingFixtures.household(), with: [
            "version": .integer(18), "roomComponents": .array([Self.changed(Self.sink), Self.sofa]),
        ]))
        let (session, transport) = try await make(initial: ShoppingFixtures.household(), reply: .success(saved))
        let change = try RoomObjectStateChange(objectID: "default-kitchen-sink", objectVersion: 0, state: "needs-cleaning")
        let result = try await session.setRoomObjectState(
            change, defaults: defaults, householdID: householdID, version: 17, mutationID: mutationID
        )

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/room-components/default-kitchen-sink/state")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "componentVersion": .integer(0), "state": .string("needs-cleaning"), "version": .integer(17),
            "mutationVersion": .integer(17), "mutationId": .string(mutationID.uuidString.lowercased()),
        ]))
        let objects = try RoomObject.list(household: #require(result.session?.household.value), defaults: defaults)
        #expect(objects.first?.state == "needs-cleaning")
    }

    @Test
    func aStateResponseThatChangesAnythingElseIsRejected() async throws {
        let defaults = try Self.defaults()
        let initial = ShoppingFixtures.replacing(ShoppingFixtures.household(), with: [
            "roomComponents": .array([Self.sink, Self.sofa]),
        ])
        let renamedSofa = ShoppingFixtures.replacing(Self.sofa, with: ["name": .string("Couch")])
        let wrongMember = ShoppingFixtures.replacing(Self.changed(Self.sink), with: [
            "stateChangedBy": ShoppingFixtures.id(ShoppingFixtures.roommateID),
        ])
        for objects in [[Self.changed(Self.sink), renamedSofa], [wrongMember, Self.sofa], [Self.sink, Self.sofa]] {
            let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(initial, with: [
                "version": .integer(18), "roomComponents": .array(objects),
            ]))
            let (session, _) = try await make(initial: initial, reply: .success(saved))
            await #expect(throws: AccountError.invalidResponse) {
                try await session.setRoomObjectState(
                    RoomObjectStateChange(objectID: "default-kitchen-sink", objectVersion: 0, state: "needs-cleaning"),
                    defaults: defaults, householdID: householdID, version: 17, mutationID: mutationID
                )
            }
            #expect(await session.state?.session?.household.value["roomComponents"] == .array([Self.sink, Self.sofa]))
        }
    }

    @Test
    func malformedStateChangesNeverReachTheServer() {
        #expect(throws: AccountError.invalidInput(.componentID)) {
            try RoomObjectStateChange(objectID: "Sink", objectVersion: 0, state: nil)
        }
        #expect(throws: AccountError.invalidInput(.state)) {
            try RoomObjectStateChange(objectID: "sink", objectVersion: 0, state: String(repeating: "a", count: 41))
        }
        #expect(throws: AccountError.invalidInput(.version)) {
            try RoomObjectStateChange(objectID: "sink", objectVersion: -1, state: nil)
        }
    }

    @Test
    func restockingAddsTheSupplyWithItsObjectSource() async throws {
        let sink = try RoomObject(Self.sink)
        let restock = try ShoppingRestock(object: sink, supply: sink.supplies[0], draft: ShoppingDraft(name: "Dish soap", quantity: "1 bottle", notes: "Kitchen: Sink"))
        let added = ShoppingFixtures.replacing(ShoppingFixtures.item, with: [
            "id": ShoppingFixtures.id(ShoppingFixtures.addedID), "name": .string("Dish soap"),
            "quantity": .string("1 bottle"), "notes": .string("Kitchen: Sink"), "version": .integer(0),
            "createdBy": ShoppingFixtures.id(ShoppingFixtures.memberID),
            "createdAt": .string(ShoppingFixtures.updatedAt), "updatedAt": .string(ShoppingFixtures.updatedAt),
            "componentSources": .array([Self.source(name: "Sink")]),
        ])
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.household(
            items: [ShoppingFixtures.item, ShoppingFixtures.otherItem, added], version: 18
        ))
        let (session, transport) = try await make(initial: ShoppingFixtures.household(), reply: .success(saved),
                                                  path: "api/shopping/items")
        try await session.restock(restock, householdID: householdID, version: 17, mutationID: mutationID)

        let request = try #require(await transport.requests.last)
        #expect(request.url?.path == "/api/shopping/items")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body["componentSource"] == .object([
            "componentId": .string("default-kitchen-sink"), "supplyId": .string("dish-soap"),
        ]))
        #expect(body["name"] == .string("Dish soap"))
    }

    @Test
    func restockingJoinsAnEntryWithTheSameNameAndRejectsAnythingElse() async throws {
        let sink = try RoomObject(Self.sink)
        let restock = try ShoppingRestock(object: sink, supply: sink.supplies[0], draft: ShoppingDraft(name: "Dish soap", quantity: "1 bottle", notes: "Kitchen: Sink"))
        let listed = ShoppingFixtures.replacing(ShoppingFixtures.otherItem, with: ["name": .string("  DISH soap ")])
        let initial = ShoppingFixtures.household(items: [ShoppingFixtures.item, listed])
        let joined = ShoppingFixtures.replacing(listed, with: [
            "version": .integer(5), "updatedAt": .string(ShoppingFixtures.updatedAt),
            "componentSources": .array([Self.source(name: "Sink")]),
        ])
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.household(items: [ShoppingFixtures.item, joined], version: 18))
        let (session, _) = try await make(initial: initial, reply: .success(saved), path: "api/shopping/items")
        try await session.restock(restock, householdID: householdID, version: 17, mutationID: mutationID)

        let requantified = ShoppingFixtures.replacing(joined, with: ["quantity": .string("9")])
        let wrong = ShoppingFixtures.withReceipt(ShoppingFixtures.household(items: [ShoppingFixtures.item, requantified], version: 18))
        let (refused, _) = try await make(initial: initial, reply: .success(wrong), path: "api/shopping/items")
        await #expect(throws: AccountError.invalidResponse) {
            try await refused.restock(restock, householdID: householdID, version: 17, mutationID: mutationID)
        }
    }

    @Test
    func onlyAnInstalledObjectsOwnSuppliesCanBeRestocked() throws {
        let sink = try RoomObject(Self.sink)
        let stored = try RoomObject(ShoppingFixtures.replacing(Self.sink, with: ["installed": .bool(false)]))
        #expect(throws: AccountError.invalidInput(.componentID)) {
            try ShoppingRestock(object: stored, supply: sink.supplies[0], draft: ShoppingDraft(name: "Dish soap"))
        }
        let other = RoomObject.Supply(id: "bleach", name: "Bleach", quantity: "1 bottle")
        #expect(throws: AccountError.invalidInput(.componentID)) {
            try ShoppingRestock(object: sink, supply: other, draft: ShoppingDraft(name: "Bleach"))
        }
        #expect(ShoppingRestock.normalized(" Ｄish SOAP ") == "dish soap")
    }

    // MARK: - Fixtures

    private enum Reply {
        case success(JSONValue), failure(Int)
    }

    private static func object(_ id: String, kind: String, slot: String, room: String = "kitchen",
                               supplies: [JSONValue] = []) -> JSONValue {
        .object([
            "id": .string(id), "kind": .string(kind), "roomId": .string(room), "slotId": .string(slot),
            "name": .string(kind.capitalized), "variant": .string("original"), "finish": .string("room"),
            "supplies": .array(supplies), "installed": .bool(true), "version": .integer(0),
            "state": .null, "stateChangedAt": .null, "stateChangedBy": .null,
        ])
    }

    private static let sink = ShoppingFixtures.replacing(object("default-kitchen-sink", kind: "sink", slot: "kitchen-sink", supplies: [
        .object(["id": .string("dish-soap"), "name": .string("Dish soap"), "quantity": .string("1 bottle")]),
    ]), with: ["name": .string("Sink")])
    private static let sofa = object("default-living-room-sofa", kind: "sofa", slot: "living-room-sofa", room: "living-room")

    private static func defaults() throws -> [RoomObject] {
        try [sink, sofa].map(RoomObject.init)
    }

    private static func changed(_ object: JSONValue) -> JSONValue {
        ShoppingFixtures.replacing(object, with: [
            "state": .string("needs-cleaning"), "stateChangedAt": .string(ShoppingFixtures.updatedAt),
            "stateChangedBy": ShoppingFixtures.id(ShoppingFixtures.memberID), "version": .integer(1),
        ])
    }

    private static func source(name: String) -> JSONValue {
        .object([
            "componentId": .string("default-kitchen-sink"), "supplyId": .string("dish-soap"),
            "roomId": .string("kitchen"), "componentName": .string(name),
        ])
    }

    private func make(initial: JSONValue, reply: Reply, path: String = "api/room-components/default-kitchen-sink/state")
        async throws -> (AccountSession, TestTransport) {
        let response: HTTPResponse
        switch reply {
        case .success(let household): response = try Fixtures.response(["household": household], path: path)
        case .failure(let status): response = try Fixtures.failure(status: status, code: nil)
        }
        let transport = TestTransport(responses: [try Fixtures.response(ShoppingFixtures.state(household: initial)), response])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        return (session, transport)
    }
}
