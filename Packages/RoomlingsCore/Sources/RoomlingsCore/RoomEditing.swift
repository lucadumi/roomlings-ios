import Foundation

/// What the room editor may change about an object (`src/componentConfiguration.ts`). Version and manual state stay with the server.
public struct RoomObjectConfiguration: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let roomID: String
    public var slotID: String
    public var name: String
    public var variant: String
    public var finish: String
    public var supplies: [RoomObject.Supply]
    public var installed: Bool

    public init(id: String, kind: String, roomID: String, slotID: String, name: String, variant: String, finish: String,
                supplies: [RoomObject.Supply], installed: Bool) {
        self.id = id
        self.kind = kind
        self.roomID = roomID
        self.slotID = slotID
        self.name = name
        self.variant = variant
        self.finish = finish
        self.supplies = supplies
        self.installed = installed
    }

    public init(_ object: RoomObject) {
        self.init(id: object.id, kind: object.kind, roomID: object.roomID, slotID: object.slotID, name: object.name,
                  variant: object.variant, finish: object.finish, supplies: object.supplies, installed: object.installed)
    }
}

/// A private room draft (`src/roomEditorDraft.ts`). Nothing reaches roommates until the draft is applied.
public struct RoomEditorDraft: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// The saved object this draft started from, or nil for a new object.
        public let base: RoomObject?
        public let value: RoomObjectConfiguration
        /// Set when the object was put in Storage: its linked chores pause until it returns.
        public let pausesChores: Bool
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public func entry(_ id: String) -> Entry? { entries.first { $0.value.id == id } }

    public func without(_ id: String) -> RoomEditorDraft {
        var next = self
        next.entries.removeAll { $0.value.id == id }
        return next
    }

    /// The room as this draft would leave it. Saved objects keep their order; new objects follow.
    public func preview(_ current: [RoomObject]) -> [RoomObjectConfiguration] {
        let ids = Set(current.map(\.id))
        return current.map { entry($0.id)?.value ?? RoomObjectConfiguration($0) }
            + entries.filter { !ids.contains($0.value.id) }.map(\.value)
    }

    public func staging(_ value: RoomObjectConfiguration, current: [RoomObject], pausesChores: Bool? = nil) -> RoomEditorDraft {
        let existing = entry(value.id)
        let base = existing.map(\.base) ?? current.first { $0.id == value.id }
        if (base == nil && !value.installed) || base.map({ RoomObjectConfiguration($0) == value }) == true { return without(value.id) }
        var next = self
        let staged = Entry(base: base, value: value, pausesChores: pausesChores ?? existing?.pausesChores ?? false)
        if let index = next.entries.firstIndex(where: { $0.value.id == value.id }) {
            next.entries[index] = staged
        } else {
            next.entries.append(staged)
        }
        return next
    }

    public func storing(_ object: RoomObjectConfiguration, current: [RoomObject], layout: RoomLayout) throws -> RoomEditorDraft {
        guard layout.slot(object.slotID)?.removable == true else {
            throw RoomEditorError("This fitted object stays in the room. You can still customize it.")
        }
        var stored = object
        stored.installed = false
        return staging(stored, current: current, pausesChores: true)
    }

    /// `roomDraftPlacementReason`: newly placed or moved objects must still fit.
    public func placementReason(_ current: [RoomObject], preview: [RoomObjectConfiguration], layout: RoomLayout) -> String? {
        let saved = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for object in preview where object.installed {
            if let previous = saved[object.id], previous.installed, previous.slotID == object.slotID { continue }
            if let reason = layout.placementReason(preview, roomID: object.roomID, kind: object.kind, slotID: object.slotID,
                                                   movingID: object.id) { return reason }
        }
        return nil
    }

    /// `stageRoomPlacement`: places the candidate, putting the chosen objects in Storage first.
    public func placing(_ candidate: RoomObjectConfiguration, storing storageIDs: [String] = [], current: [RoomObject],
                        layout: RoomLayout) throws -> RoomEditorDraft {
        var value = candidate
        value.installed = true
        let accepted = preview(current)
        var next = self
        for id in storageIDs {
            guard let object = accepted.first(where: { $0.id == id && $0.roomID == candidate.roomID && $0.installed }),
                  object.id != candidate.id else {
                throw RoomEditorError("Review the objects chosen for Storage before placing this object.")
            }
            next = try next.storing(object, current: current, layout: layout)
        }
        next = next.staging(value, current: current)
        let preview = next.preview(current)
        if let reason = layout.validate(preview) ?? next.placementReason(current, preview: preview, layout: layout) {
            throw RoomEditorError(reason)
        }
        return next
    }

    /// The room shown while a placement is previewed: the candidate in place and its swap choices stored.
    public static func inspection(_ accepted: [RoomObjectConfiguration], candidate: RoomObjectConfiguration,
                                  storing storageIDs: [String] = []) -> [RoomObjectConfiguration] {
        let present = accepted.contains { $0.id == candidate.id }
        let preview = accepted.map { object -> RoomObjectConfiguration in
            if object.id == candidate.id { return candidate }
            guard object.installed, object.roomID == candidate.roomID,
                  object.slotID == candidate.slotID || storageIDs.contains(object.id) else { return object }
            var stored = object
            stored.installed = false
            return stored
        }
        return present ? preview : preview + [candidate]
    }

    /// Drafts whose saved object changed or disappeared since they were started.
    public func conflicts(_ current: [RoomObject]) -> [Entry] {
        entries.filter { entry in
            let latest = current.first { $0.id == entry.value.id }
            return entry.base.map { latest?.version != $0.version } ?? (latest != nil)
        }
    }

    /// Keeps this draft's own edits on top of a roommate's newer save (the web's Keep my draft).
    public func keeping(_ id: String, latest: RoomObject) -> RoomEditorDraft {
        guard let entry = entry(id) else { return self }
        let base = entry.base.map(RoomObjectConfiguration.init)
        var value = RoomObjectConfiguration(latest)
        if base == nil || base?.name != entry.value.name { value.name = entry.value.name }
        if base == nil || base?.variant != entry.value.variant { value.variant = entry.value.variant }
        if base == nil || base?.finish != entry.value.finish { value.finish = entry.value.finish }
        if base == nil || base?.supplies != entry.value.supplies { value.supplies = entry.value.supplies }
        if base == nil || base?.installed != entry.value.installed { value.installed = entry.value.installed }
        if base == nil || base?.slotID != entry.value.slotID { value.slotID = entry.value.slotID }
        var next = without(id)
        if RoomObjectConfiguration(latest) != value {
            next.entries.append(Entry(base: latest, value: value, pausesChores: entry.pausesChores))
        }
        return next
    }

    /// The request for Apply for everyone, checked as `roomComponentsPatchSchema` checks it.
    public func patch(roomID: String, layout: RoomLayout) throws -> RoomObjectsPatch {
        try RoomObjectsPatch(roomID: roomID, entries: entries, layout: layout)
    }
}

public struct RoomEditorError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A validated room layout change. Names are trimmed as the server stores them.
public struct RoomObjectsPatch: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public let value: RoomObjectConfiguration
        public let baseVersion: Int64?
        public let pausesChores: Bool
    }

    public let roomID: String
    public let changes: [Change]

    init(roomID: String, entries: [RoomEditorDraft.Entry], layout: RoomLayout) throws {
        guard !entries.isEmpty else { throw RoomEditorError("Change an object before applying.") }
        guard entries.count <= layout.objectLimit else {
            throw RoomEditorError("This home has reached its saved-object limit. Restore an existing object instead.")
        }
        guard Set(entries.map(\.value.id)).count == entries.count else { throw RoomEditorError("Update each object only once.") }
        guard entries.allSatisfy({ $0.value.roomID == roomID }) else { throw RoomEditorError("Apply changes to one room at a time.") }
        self.roomID = roomID
        changes = try entries.map { entry in
            var value = entry.value
            func fail(_ message: String) -> RoomEditorError {
                RoomEditorError("\(value.name.trimmed.isEmpty ? layout.name(value.kind) : value.name.trimmed): \(message)")
            }
            value.name = value.name.trimmed
            guard !value.name.isEmpty else { throw fail("Give this object a name.") }
            guard value.name.count <= 50 else { throw fail("Use 50 characters or fewer for the name.") }
            guard let position = layout.slot(value.slotID), position.roomID == value.roomID, position.kinds.contains(value.kind) else {
                throw fail("This object does not fit that room position.")
            }
            guard position.removable || value.installed else { throw fail("This fitted object stays in the room. You can still customize it.") }
            guard value.supplies.count <= layout.supplyLimit else {
                throw fail("An object can have up to \(layout.supplyLimit) supply shortcuts.")
            }
            value.supplies = try value.supplies.map { supply in
                let name = supply.name.trimmed
                let quantity = supply.quantity.trimmed
                guard !name.isEmpty else { throw fail("Name this supply.") }
                guard !quantity.isEmpty else { throw fail("Enter a supply quantity.") }
                guard name.count <= 50, quantity.count <= 40 else { throw fail("Shorten this supply's name or quantity.") }
                return RoomObject.Supply(id: supply.id, name: name, quantity: quantity)
            }
            guard Set(value.supplies.map(\.id)).count == value.supplies.count else { throw fail("Choose each supply only once.") }
            guard Set(value.supplies.map { ShoppingRestock.normalized($0.name) }).count == value.supplies.count else {
                throw fail("Use a distinct name for each supply.")
            }
            guard HouseholdValidation.componentID(value.id), value.supplies.allSatisfy({ HouseholdValidation.componentID($0.id) }) else {
                throw fail("Choose a valid room object.")
            }
            if entry.base == nil {
                guard UUID(uuidString: value.id)?.uuidString.lowercased() == value.id, value.installed else {
                    throw fail("Add a new object with a fresh identifier, or restore a saved object.")
                }
            }
            return Change(value: value, baseVersion: entry.base?.version,
                          pausesChores: entry.pausesChores && !value.installed)
        }
    }

    var fields: [String: JSONValue] {
        ["roomId": .string(roomID), "changes": .array(changes.map { change in
            var fields: [String: JSONValue] = [
                "id": .string(change.value.id), "kind": .string(change.value.kind), "roomId": .string(change.value.roomID),
                "slotId": .string(change.value.slotID), "name": .string(change.value.name),
                "variant": .string(change.value.variant), "finish": .string(change.value.finish),
                "supplies": .array(change.value.supplies.map {
                    .object(["id": .string($0.id), "name": .string($0.name), "quantity": .string($0.quantity)])
                }),
                "installed": .bool(change.value.installed),
                "componentVersion": change.baseVersion.map(JSONValue.integer) ?? .null,
            ]
            if change.pausesChores { fields["linkedChores"] = .string("pause") }
            return .object(fields)
        })]
    }

    /// The server applies each change at the next version and leaves state, other objects and chores untouched.
    func matches(_ result: HouseholdRoomObjects, from original: HouseholdRoomObjects, defaults: [RoomObject]) -> Bool {
        let saved = original.raw.map { JSONValue.object(["roomComponents": $0]) } ?? .object([:])
        guard result.preserved == original.preserved,
              let before = try? RoomObject.list(household: saved, defaults: defaults),
              let values = result.raw?.arrayValue, let after = try? values.map(RoomObject.init) else { return false }
        let existing = Set(before.map(\.id))
        let added = changes.filter { !existing.contains($0.value.id) }
        guard after.map(\.id) == before.map(\.id) + added.map(\.value.id) else { return false }
        for object in after {
            guard let change = changes.first(where: { $0.value.id == object.id }) else {
                guard before.first(where: { $0.id == object.id })?.value == object.value else { return false }
                continue
            }
            let previous = before.first { $0.id == object.id }
            guard previous?.version == change.baseVersion, RoomObjectConfiguration(object) == change.value,
                  object.version == previous.map({ $0.version + 1 }) ?? 0, object.state == previous?.state,
                  object.stateChangedAt == previous?.stateChangedAt, object.stateChangedBy == previous?.stateChangedBy
            else { return false }
        }
        return true
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension AccountAPI {
    func updateRoomObjects(
        _ patch: RoomObjectsPatch, defaults: [RoomObject], version: Int64, mutationID: UUID, memberID: UUID,
        current: HouseholdRoomObjects, token: SessionToken
    ) async throws -> RoomObjectMutationResponse {
        let response: RoomObjectMutationResponse = try await client.mutation(
            .updateRoomObjects, fields: patch.fields, version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == current.householdVersion, patch.matches(response.projection, from: current, defaults: defaults) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}
