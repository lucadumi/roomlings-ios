import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Room editing", .timeLimit(.minutes(1)))
struct RoomEditingTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let mutationID = ShoppingFixtures.mutationID
    private static let newID = "6f1c2b7e-1d1f-4f53-9d55-0c3f3e2a9b10"

    @Test
    func placementFollowsPositionsZonesAndRequirements() throws {
        let layout = try Self.layout()
        let room = try Self.current().map(RoomObjectConfiguration.init)
        // The counter zone holds one object, and the toaster spot is taken.
        #expect(layout.placementReason(room, roomID: "kitchen", kind: "toaster", slotID: "kitchen-toaster")
            == "Occupied by Toaster.")
        #expect(layout.placementReason(room, roomID: "kitchen", kind: "toaster", slotID: "kitchen-appliance")
            == "Counter 1 of 1. Make room first.")
        #expect(layout.placementReason(room, roomID: "kitchen", kind: "tray", slotID: "kitchen-tray")
            == "This position needs the bathtub.")
        #expect(layout.placementReason(room, roomID: "kitchen", kind: "bread-box", slotID: "kitchen-appliance")?
            .hasPrefix("Bread box is no longer offered") == true)
        // Moving the toaster frees its own zone place.
        #expect(layout.placementReason(room, roomID: "kitchen", kind: "toaster", slotID: "kitchen-appliance", movingID: "toaster") == nil)

        let toaster = layout.availability(kind: "toaster", roomID: "kitchen", preview: room, saved: room)
        #expect(toaster.status == .placed && toaster.label == "Placed")
        let kettle = layout.availability(kind: "kettle", roomID: "kitchen", preview: room, saved: room)
        #expect(kettle.status == .available && kettle.label == "Available to add" && kettle.position?.id == "kitchen-kettle")
        #expect(layout.validate(room) == nil)
        #expect(layout.validate(room.filter { $0.id != "default-kitchen-sink" })
            == "Keep the fitted objects and household tools in their room positions.")
    }

    @Test
    func draftsPlaceStoreAndSwapLikeTheWeb() throws {
        let layout = try Self.layout()
        let current = try Self.current()
        let kettle = try #require(layout.newObject(kind: "kettle", slotID: "kitchen-kettle", id: Self.newID))
        #expect(kettle.name == "Kettle" && kettle.supplies.map(\.id) == ["descaler"])

        var draft = try RoomEditorDraft().placing(kettle, current: current, layout: layout)
        #expect(draft.preview(current).map(\.id) == ["default-kitchen-sink", "toaster", Self.newID])

        // A blocked counter placement needs the toaster in Storage first.
        let mixer = try #require(layout.newObject(kind: "toaster", slotID: "kitchen-appliance", id: "6f1c2b7e-1d1f-4f53-9d55-0c3f3e2a9b11"))
        #expect(throws: RoomEditorError("Counter 1 of 1. Make room first.")) {
            try draft.placing(mixer, current: current, layout: layout)
        }
        draft = try draft.placing(mixer, storing: ["toaster"], current: current, layout: layout)
        let stored = try #require(draft.entry("toaster"))
        #expect(!stored.value.installed && stored.pausesChores)
        #expect(throws: RoomEditorError("This fitted object stays in the room. You can still customize it.")) {
            try draft.storing(RoomObjectConfiguration(current[0]), current: current, layout: layout)
        }

        // Undoing every edit leaves no draft, and an unsaved trial put away is discarded.
        var restored = RoomObjectConfiguration(current[1])
        restored.installed = true
        #expect(draft.staging(restored, current: current).entry("toaster") == nil)
        #expect(try draft.storing(kettle, current: current, layout: layout).entry(Self.newID) == nil)

        let shown = RoomEditorDraft.inspection(RoomEditorDraft().preview(current), candidate: mixer, storing: ["toaster"])
        #expect(shown.map(\.installed) == [true, false, true])
    }

    @Test
    func roommateChangesAreConflictsThatCanBeKeptOrDropped() throws {
        let layout = try Self.layout()
        let current = try Self.current()
        var renamed = RoomObjectConfiguration(current[1])
        renamed.name = "Old toaster"
        let draft = RoomEditorDraft().staging(renamed, current: current)
        #expect(draft.conflicts(current).isEmpty)

        let newer = try RoomObject(ShoppingFixtures.replacing(Self.toaster, with: ["version": .integer(3), "finish": .string("sage")]))
        let latest = [current[0], newer]
        #expect(draft.conflicts(latest).map(\.value.id) == ["toaster"])
        let kept = draft.keeping("toaster", latest: newer)
        #expect(kept.conflicts(latest).isEmpty)
        #expect(kept.entry("toaster")?.value.name == "Old toaster" && kept.entry("toaster")?.value.finish == "sage")
        #expect(try kept.patch(roomID: "kitchen", layout: layout).changes.first?.baseVersion == 3)
    }

    @Test
    func patchesAreCheckedAndTrimmedBeforeSending() throws {
        let layout = try Self.layout()
        let current = try Self.current()
        var toaster = RoomObjectConfiguration(current[1])
        toaster.name = "  Toasty  "
        toaster.supplies = [RoomObject.Supply(id: "bread", name: " Bread ", quantity: " 1 loaf ")]
        let patch = try RoomEditorDraft().staging(toaster, current: current).patch(roomID: "kitchen", layout: layout)
        #expect(patch.changes.first?.value.name == "Toasty")
        #expect(patch.changes.first?.value.supplies == [RoomObject.Supply(id: "bread", name: "Bread", quantity: "1 loaf")])

        for (change, message) in [
            ({ (object: inout RoomObjectConfiguration) in object.name = " " }, "Toaster: Give this object a name."),
            ({ $0.supplies = [RoomObject.Supply(id: "a", name: "Bread", quantity: "1"), RoomObject.Supply(id: "b", name: "bread", quantity: "2")] },
             "Toaster: Use a distinct name for each supply."),
            ({ $0.supplies = [RoomObject.Supply(id: "a", name: "Bread", quantity: "")] }, "Toaster: Enter a supply quantity."),
        ] as [((inout RoomObjectConfiguration) -> Void, String)] {
            var object = RoomObjectConfiguration(current[1])
            change(&object)
            #expect(throws: RoomEditorError(message)) {
                try RoomEditorDraft().staging(object, current: current).patch(roomID: "kitchen", layout: layout)
            }
        }
        let trial = try #require(layout.newObject(kind: "kettle", slotID: "kitchen-kettle", id: "preview-kettle"))
        #expect(throws: RoomEditorError("Kettle: Add a new object with a fresh identifier, or restore a saved object.")) {
            try RoomEditorDraft().staging(trial, current: current).patch(roomID: "kitchen", layout: layout)
        }
        #expect(throws: RoomEditorError("Change an object before applying.")) {
            try RoomEditorDraft().patch(roomID: "kitchen", layout: layout)
        }
    }

    @Test
    func applyingSendsTheDraftAndAcceptsOnlyTheMatchingLayout() async throws {
        let layout = try Self.layout()
        let current = try Self.current()
        let initial = ShoppingFixtures.replacing(ShoppingFixtures.household(), with: [
            "roomComponents": .array([Self.sink, Self.toaster]),
        ])
        let kettle = try #require(layout.newObject(kind: "kettle", slotID: "kitchen-kettle", id: Self.newID))
        let draft = try RoomEditorDraft().placing(kettle, current: current, layout: layout)
            .storing(RoomObjectConfiguration(current[1]), current: current, layout: layout)
        let patch = try draft.patch(roomID: "kitchen", layout: layout)

        let storedToaster = ShoppingFixtures.replacing(Self.toaster, with: ["installed": .bool(false), "version": .integer(2)])
        let savedKettle = Self.object(Self.newID, kind: "kettle", slot: "kitchen-kettle", supplies: [
            .object(["id": .string("descaler"), "name": .string("Descaler"), "quantity": .string("1 bottle")]),
        ])
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(initial, with: [
            "version": .integer(18), "roomComponents": .array([Self.sink, storedToaster, savedKettle]),
        ]))
        let (session, transport) = try await make(initial: initial, reply: saved)
        let result = try await session.updateRoomObjects(
            patch, defaults: current, householdID: householdID, version: 17, mutationID: mutationID
        )
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/household/room-components")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body["roomId"] == .string("kitchen"))
        let changes = try #require(body["changes"]?.arrayValue)
        #expect(changes.map { $0["id"] } == [.string(Self.newID), .string("toaster")])
        #expect(changes.map { $0["componentVersion"] } == [.null, .integer(1)])
        #expect(changes.map { $0["linkedChores"] } == [nil, .string("pause")])
        let objects = try RoomObject.list(household: #require(result.session?.household.value), defaults: current)
        #expect(objects.map(\.installed) == [true, false, true])

        // A response that also changes another object, or drops a change, is never accepted.
        let renamedSink = ShoppingFixtures.replacing(Self.sink, with: ["name": .string("Basin")])
        for layout in [[renamedSink, storedToaster, savedKettle], [Self.sink, Self.toaster, savedKettle]] {
            let wrong = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(initial, with: [
                "version": .integer(18), "roomComponents": .array(layout),
            ]))
            let (session, _) = try await make(initial: initial, reply: wrong)
            await #expect(throws: AccountError.invalidResponse) {
                try await session.updateRoomObjects(patch, defaults: current, householdID: householdID, version: 17, mutationID: mutationID)
            }
            #expect(await session.state?.session?.household.value["roomComponents"] == .array([Self.sink, Self.toaster]))
        }
    }

    // MARK: - Fixtures

    private static func object(_ id: String, kind: String, slot: String, version: Int64 = 0, supplies: [JSONValue] = []) -> JSONValue {
        .object([
            "id": .string(id), "kind": .string(kind), "roomId": .string("kitchen"), "slotId": .string(slot),
            "name": .string(kind.prefix(1).uppercased() + kind.dropFirst()), "variant": .string("original"),
            "finish": .string("room"), "supplies": .array(supplies), "installed": .bool(true), "version": .integer(version),
            "state": .null, "stateChangedAt": .null, "stateChangedBy": .null,
        ])
    }

    private static let sink = object("default-kitchen-sink", kind: "sink", slot: "kitchen-sink")
    private static let toaster = object("toaster", kind: "toaster", slot: "kitchen-toaster", version: 1)

    private static func current() throws -> [RoomObject] {
        try [sink, toaster].map(RoomObject.init)
    }

    private static func layout() throws -> RoomLayout {
        let json = """
        {
          "objectLimit": 160, "supplyLimit": 12,
          "kindOrder": ["sink", "kettle", "toaster", "tray", "bread-box"],
          "finishOrder": ["room", "sage"], "finishColors": {"sage": "#81b29a"},
          "categories": [{"id": "appliances", "name": "Appliances"}],
          "kinds": {
            "sink": {"name": "Sink", "category": "fixtures", "retired": false, "placementRooms": null, "placementSlots": null,
              "rooms": {"kitchen": {"name": "Sink", "supplies": {"original": []}}}},
            "kettle": {"name": "Kettle", "category": "appliances", "retired": false, "placementRooms": null, "placementSlots": null,
              "rooms": {"kitchen": {"name": "Kettle", "supplies": {"original": [{"id": "descaler", "name": "Descaler", "quantity": "1 bottle"}]}}}},
            "toaster": {"name": "Toaster", "category": "appliances", "retired": false, "placementRooms": null, "placementSlots": null,
              "rooms": {"kitchen": {"name": "Toaster", "supplies": {"original": []}}}},
            "tray": {"name": "Tray", "category": "decor", "retired": false, "placementRooms": null, "placementSlots": null,
              "rooms": {"kitchen": {"name": "Tray", "supplies": {"original": []}}}},
            "bread-box": {"name": "Bread box", "category": "appliances", "retired": true, "placementRooms": null, "placementSlots": null,
              "rooms": {"kitchen": {"name": "Bread box", "supplies": {"original": []}}}}
          },
          "slots": [
            {"id": "kitchen-sink", "roomId": "kitchen", "name": "Fitted sink", "kinds": ["sink"], "removable": false, "requires": null, "surface": null},
            {"id": "kitchen-kettle", "roomId": "kitchen", "name": "Kettle spot", "kinds": ["kettle"], "removable": true, "requires": null, "surface": null},
            {"id": "kitchen-toaster", "roomId": "kitchen", "name": "Toaster spot", "kinds": ["toaster"], "removable": true, "requires": null, "surface": "counter"},
            {"id": "kitchen-appliance", "roomId": "kitchen", "name": "Small appliance", "kinds": ["toaster", "bread-box"], "removable": true, "requires": null, "surface": "counter"},
            {"id": "kitchen-tray", "roomId": "kitchen", "name": "Bath edge", "kinds": ["tray"], "removable": true,
              "requires": {"slotId": "kitchen-bath", "variant": "original", "message": "This position needs the bathtub."}, "surface": null}
          ],
          "zones": [{"id": "counter", "label": "Counter"}],
          "zoneCapacities": {"kitchen": {"counter": 1}}
        }
        """
        return try JSONDecoder().decode(RoomLayout.self, from: Data(json.utf8))
    }

    private func make(initial: JSONValue, reply: JSONValue) async throws -> (AccountSession, TestTransport) {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: initial)),
            try Fixtures.response(["household": reply], path: "api/household/room-components"),
        ])
        let session = AccountSession(
            configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport
        )
        try await session.restore()
        return (session, transport)
    }
}
