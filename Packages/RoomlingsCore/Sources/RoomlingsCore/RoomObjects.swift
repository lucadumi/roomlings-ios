import Foundation

/// A room object as the shared household saves it (`shared/roomComponents.ts`).
public struct RoomObject: Sendable, Equatable, Identifiable {
    public struct Supply: Sendable, Equatable, Hashable, Identifiable, Decodable {
        public let id: String
        public let name: String
        public let quantity: String

        public init(id: String, name: String, quantity: String) {
            self.id = id
            self.name = name
            self.quantity = quantity
        }
    }

    public let id: String
    public let kind: String
    public let roomID: String
    public let slotID: String
    public let name: String
    public let variant: String
    public let finish: String
    public let supplies: [Supply]
    public let installed: Bool
    public let version: Int64
    public let state: String?
    public let stateChangedAt: String?
    public let stateChangedBy: UUID?
    /// The saved record, kept so a state change can be checked field by field.
    let value: JSONValue

    public init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.string("id")
        kind = try fields.string("kind")
        roomID = try fields.string("roomId")
        slotID = try fields.string("slotId")
        name = try fields.text("name", length: 1...50)
        variant = try fields.text("variant", length: 1...40)
        finish = try fields.string("finish")
        let supplies = try fields.array("supplies")
        guard supplies.count <= 12 else { throw AccountError.invalidResponse }
        self.supplies = try supplies.map { supply in
            let fields = try HouseholdFields(supply)
            let id = try fields.string("id")
            guard HouseholdValidation.componentID(id) else { throw AccountError.invalidResponse }
            return Supply(id: id, name: try fields.text("name", length: 1...50),
                          quantity: try fields.text("quantity", length: 1...40))
        }
        installed = try fields.bool("installed")
        version = try fields.integer("version")
        state = try fields.nullableString("state")
        stateChangedAt = try fields.nullableString("stateChangedAt")
        stateChangedBy = try fields.nullableUUID("stateChangedBy")
        guard HouseholdValidation.componentID(id), HouseholdValidation.componentID(kind),
              HouseholdValidation.componentID(slotID), HouseholdValidation.componentID(finish),
              ChoreValidation.areas[roomID] != nil,
              state.map({ (1...40).contains($0.utf16.count) }) ?? true,
              stateChangedAt.map(AccountValidation.timestamp) ?? true,
              (stateChangedAt == nil) == (stateChangedBy == nil) else { throw AccountError.invalidResponse }
        self.value = value
    }

    /// The household's objects as the web reads them with `getRoomComponents`: saved layouts keep their
    /// identities, retired placements move to Storage, and layouts saved before the living room gain its defaults.
    public static func list(household: JSONValue, defaults: [RoomObject]) throws -> [RoomObject] {
        guard let raw = household["roomComponents"] else { return defaults }
        guard let values = raw.arrayValue, values.count <= 160 else { throw AccountError.invalidResponse }
        var objects = try values.map(RoomObject.init).map { $0.retiringPlacement() }
        if !objects.contains(where: { $0.roomID == "living-room" }) {
            objects += defaults.filter { $0.roomID == "living-room" }
        }
        guard Set(objects.map(\.id)).count == objects.count else { throw AccountError.invalidResponse }
        return objects
    }

    private func retiringPlacement() -> RoomObject {
        guard installed, kind == "bread-box" || (kind == "bins" && roomID == "living-room"),
              case .object(var object) = value else { return self }
        object["installed"] = .bool(false)
        // A record built from a valid record with one Boolean changed always parses.
        return (try? RoomObject(.object(object))) ?? self
    }
}

/// Everything a room object state change must leave untouched.
public struct HouseholdRoomObjects: Sendable, Equatable {
    public let householdVersion: Int64
    public let members: [HouseholdMember]
    let raw: JSONValue?
    let preserved: JSONValue

    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    public init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        raw = household.value["roomComponents"]
        guard case .object(var object) = household.value else { throw AccountError.invalidResponse }
        for key in ["roomComponents", "version", "mutationReceipts"] { object[key] = nil }
        preserved = .object(object)
    }
}

extension HouseholdRoomObjects: HouseholdProjection {
    static let collectionKey = "roomComponents"
}

typealias RoomObjectMutationResponse = HouseholdMutationResponse<HouseholdRoomObjects>

/// A manual state change for one object. Only the state fields and the object's version may change.
public struct RoomObjectStateChange: Sendable, Equatable {
    public let objectID: String
    public let objectVersion: Int64
    public let state: String?

    public init(objectID: String, objectVersion: Int64, state: String?) throws {
        guard HouseholdValidation.componentID(objectID) else { throw AccountError.invalidInput(.componentID) }
        guard (0...(HouseholdValidation.maximumInteger - 1)).contains(objectVersion) else {
            throw AccountError.invalidInput(.version)
        }
        guard state.map({ (1...40).contains($0.utf16.count) }) ?? true else { throw AccountError.invalidInput(.state) }
        self.objectID = objectID
        self.objectVersion = objectVersion
        self.state = state
    }

    func matches(_ result: HouseholdRoomObjects, from original: HouseholdRoomObjects,
                 defaults: [RoomObject], memberID: UUID) -> Bool {
        let saved = original.raw.map { JSONValue.object(["roomComponents": $0]) } ?? .object([:])
        guard result.preserved == original.preserved,
              let before = try? RoomObject.list(household: saved, defaults: defaults),
              let values = result.raw?.arrayValue, let after = try? values.map(RoomObject.init),
              after.map(\.id) == before.map(\.id),
              let previous = before.first(where: { $0.id == objectID }), previous.installed,
              previous.version == objectVersion, previous.state != state else { return false }
        for (old, new) in zip(before, after) where old.id != objectID {
            guard old.value == new.value else { return false }
        }
        guard let updated = after.first(where: { $0.id == objectID }), updated.version == previous.version + 1,
              updated.state == state, updated.stateChangedBy == memberID, updated.stateChangedAt != nil,
              case .object(var expected) = previous.value, case .object(var actual) = updated.value else { return false }
        for key in ["state", "stateChangedAt", "stateChangedBy", "version"] {
            expected[key] = nil
            actual[key] = nil
        }
        return expected == actual
    }
}

extension AccountAPI {
    func setRoomObjectState(
        _ change: RoomObjectStateChange, defaults: [RoomObject], version: Int64, mutationID: UUID, memberID: UUID,
        current: HouseholdRoomObjects, token: SessionToken
    ) async throws -> RoomObjectMutationResponse {
        let response: RoomObjectMutationResponse = try await client.mutation(
            .setRoomObjectState(change.objectID),
            fields: ["componentVersion": .integer(change.objectVersion), "state": change.state.map(JSONValue.string) ?? .null],
            version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == current.householdVersion,
                  change.matches(response.projection, from: current, defaults: defaults, memberID: memberID) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}
