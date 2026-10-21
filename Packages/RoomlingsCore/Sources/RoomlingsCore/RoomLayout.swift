import Foundation

/// The room editor's placement data, generated from `shared/roomComponents.ts` and `shared/roomZones.ts`.
/// Its rules mirror `src/componentAvailability.ts`; the server checks the same rules when a layout is applied.
public struct RoomLayout: Decodable, Sendable {
    public struct Option: Decodable, Sendable, Hashable {
        public let id: String
        public let name: String
    }

    public struct Zone: Decodable, Sendable, Hashable {
        public let id: String
        public let label: String
    }

    public struct Requirement: Decodable, Sendable, Hashable {
        public let slotID: String
        public let variant: String
        public let message: String

        private enum CodingKeys: String, CodingKey { case slotID = "slotId", variant, message }
    }

    public struct Slot: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let roomID: String
        public let name: String
        public let kinds: [String]
        public let removable: Bool
        public let requires: Requirement?
        public let surface: String?

        private enum CodingKeys: String, CodingKey { case id, roomID = "roomId", name, kinds, removable, requires, surface }
    }

    public struct Fresh: Decodable, Sendable {
        public let name: String
        /// Suggested supply shortcuts by model.
        public let supplies: [String: [RoomObject.Supply]]
    }

    public struct Kind: Decodable, Sendable {
        public let name: String
        public let category: String
        public let retired: Bool
        public let placementRooms: [String]?
        public let placementSlots: [String]?
        /// A new object's name and suggested supplies in each room that has a position for it.
        public let rooms: [String: Fresh]
    }

    public let objectLimit: Int
    public let supplyLimit: Int
    public let kindOrder: [String]
    public let finishOrder: [String]
    public let finishColors: [String: String]
    public let categories: [Option]
    public let kinds: [String: Kind]
    public let slots: [Slot]
    public let zones: [Zone]
    public let zoneCapacities: [String: [String: Int]]

    public func slot(_ id: String) -> Slot? { slots.first { $0.id == id } }

    public func name(_ kind: String) -> String { kinds[kind]?.name ?? kind }

    // MARK: - shared/roomComponents.ts

    public func isRetired(_ kind: String) -> Bool { kinds[kind]?.retired ?? true }

    /// Historical positions remain valid; this only controls new placements.
    public func offered(_ kind: String, at slotID: String) -> Bool {
        kinds[kind]?.placementSlots.map { $0.contains(slotID) } ?? true
    }

    public func allowed(_ kind: String, in roomID: String) -> Bool {
        guard let definition = kinds[kind], !definition.retired else { return false }
        return (definition.placementRooms?.contains(roomID) ?? true) && slots.contains {
            $0.roomID == roomID && $0.kinds.contains(kind) && offered(kind, at: $0.id)
        }
    }

    public func supported(_ slotID: String, among objects: [RoomObjectConfiguration]) -> Bool {
        guard let position = slot(slotID) else { return false }
        guard let requirement = position.requires else { return true }
        return objects.contains { $0.installed && $0.slotID == requirement.slotID && $0.variant == requirement.variant }
    }

    public func availableSlots(_ objects: [RoomObjectConfiguration], roomID: String, kind: String, surface: String? = nil,
                               movingID: String? = nil, ignoreZoneCapacity: Bool = false) -> [Slot] {
        guard allowed(kind, in: roomID) else { return [] }
        let moving = objects.first { $0.id == movingID && $0.kind == kind && $0.roomID == roomID }
        return slots.filter { slot in
            slot.roomID == roomID && slot.kinds.contains(kind) && (surface == nil || slot.surface == surface)
                && offered(kind, at: slot.id) && supported(slot.id, among: objects)
                && !objects.contains { $0.installed && $0.slotID == slot.id && $0.id != moving?.id }
                && (ignoreZoneCapacity || (moving?.installed == true && moving?.slotID == slot.id)
                    || zoneReason(objects, roomID: roomID, slotID: slot.id, movingID: moving?.id) == nil)
        }
    }

    /// A new object as `createRoomComponent` makes it. Returns nil for a position that does not take this kind.
    public func newObject(kind: String, slotID: String, id: String) -> RoomObjectConfiguration? {
        guard let position = slot(slotID), position.kinds.contains(kind),
              let fresh = kinds[kind]?.rooms[position.roomID] else { return nil }
        return RoomObjectConfiguration(
            id: id, kind: kind, roomID: position.roomID, slotID: slotID, name: fresh.name, variant: "original",
            finish: "room", supplies: fresh.supplies["original"] ?? [], installed: true
        )
    }

    public func suggestedSupplies(_ object: RoomObjectConfiguration) -> [RoomObject.Supply] {
        kinds[object.kind]?.rooms[object.roomID]?.supplies[object.variant] ?? []
    }

    /// `validateRoomComponents`: distinct identities, supported and unshared positions, and every fitted object in place.
    public func validate(_ objects: [RoomObjectConfiguration]) -> String? {
        if objects.count > objectLimit { return "This home has reached its saved-object limit. Restore an existing object instead." }
        var ids = Set<String>()
        var installed = Set<String>()
        for object in objects {
            guard ids.insert(object.id).inserted else { return "Room objects must have distinct identifiers." }
            guard object.installed else { continue }
            if !supported(object.slotID, among: objects) {
                return slot(object.slotID)?.requires?.message ?? "This position is not supported by the current room."
            }
            guard installed.insert(object.slotID).inserted else { return "Two objects cannot occupy the same designed position." }
        }
        if slots.contains(where: { !$0.removable && !installed.contains($0.id) }) {
            return "Keep the fitted objects and household tools in their room positions."
        }
        return nil
    }

    // MARK: - shared/roomZones.ts

    public struct ZoneUsage: Sendable, Hashable {
        public let surface: String
        public let label: String
        public let used: Int
        public let capacity: Int
    }

    public func zoneUsage(_ objects: [RoomObjectConfiguration], roomID: String) -> [ZoneUsage] {
        var counts: [String: Int] = [:]
        for object in objects where object.installed && object.roomID == roomID {
            if let surface = slot(object.slotID)?.surface { counts[surface, default: 0] += 1 }
        }
        let capacities = zoneCapacities[roomID] ?? [:]
        return zones.compactMap { zone in
            capacities[zone.id].map { ZoneUsage(surface: zone.id, label: zone.label, used: counts[zone.id] ?? 0, capacity: $0) }
        }
    }

    public func zoneReason(_ objects: [RoomObjectConfiguration], roomID: String, slotID: String, movingID: String? = nil) -> String? {
        guard let surface = slot(slotID)?.surface,
              let zone = zoneUsage(objects.filter { $0.id != movingID }, roomID: roomID).first(where: { $0.surface == surface }),
              zone.used >= zone.capacity else { return nil }
        return "\(zone.label) \(zone.used) of \(zone.capacity). Make room first."
    }

    // MARK: - src/componentAvailability.ts

    private func retiredReason(_ kind: String) -> String {
        "\(name(kind)) is no longer offered for new placements. Its settings and history are kept, but it cannot be moved or brought back."
    }

    public func preferredSlot(kind: String, among available: [Slot], objects: [RoomObjectConfiguration], objectID: String? = nil) -> Slot? {
        let chosen = objectID.flatMap { id in objects.first { $0.id == id && $0.kind == kind } }
        return available.first { $0.id == chosen?.slotID }
            ?? available.first { slot in
                objects.contains { $0.kind == kind && $0.slotID == slot.id && !$0.installed && (objectID == nil || $0.id == objectID) }
            }
            ?? available.first { $0.kinds.count == 1 }
            ?? available.first
    }

    public func placementReason(_ objects: [RoomObjectConfiguration], roomID: String, kind: String, slotID: String,
                                movingID: String? = nil) -> String? {
        let name = name(kind)
        if isRetired(kind) { return retiredReason(kind) }
        if !allowed(kind, in: roomID) { return "\(name) is not available for new placements in this room." }
        guard let position = slot(slotID), position.roomID == roomID, position.kinds.contains(kind), offered(kind, at: slotID) else {
            return "\(name) is not available for new placements in that position."
        }
        if !supported(slotID, among: objects) { return position.requires?.message ?? "This position needs its required fixture." }
        if let occupant = objects.first(where: { $0.installed && $0.slotID == slotID && $0.id != movingID }) {
            return "Occupied by \(occupant.name.isEmpty ? self.name(occupant.kind) : occupant.name)."
        }
        let zone = zoneReason(objects, roomID: roomID, slotID: slotID, movingID: movingID)
        if zone == nil, availableSlots(objects, roomID: roomID, kind: kind, movingID: movingID).contains(where: { $0.id == slotID }) {
            return nil
        }
        return zone ?? "No compatible position is available."
    }

    public struct Availability: Sendable {
        public enum Status: String, Sendable { case available, placed, preview, occupied }
        public let status: Status
        public let label: String
        public let placed: Int
        public let free: Int
        public let positions: [Slot]
        public let available: [Slot]
        public let position: Slot?
        public let instance: RoomObjectConfiguration?
        public let stored: RoomObjectConfiguration?
        public let reason: String?
    }

    public func availability(kind: String, roomID: String, preview: [RoomObjectConfiguration], saved: [RoomObjectConfiguration],
                             surface: String? = nil, selectedID: String? = nil, storedID: String? = nil,
                             movingID: String? = nil) -> Availability {
        let placed = preview.filter { $0.installed && $0.roomID == roomID && $0.kind == kind }
        let inZone = placed.filter { surface == nil || slot($0.slotID)?.surface == surface }
        let instance = inZone.first { $0.id == selectedID } ?? inZone.first
            ?? placed.first { $0.id == selectedID } ?? placed.first
        let existing = saved.filter { $0.installed && $0.roomID == roomID && $0.kind == kind }
        let available = availableSlots(preview, roomID: roomID, kind: kind, surface: surface, movingID: movingID)
        let positions = allowed(kind, in: roomID) ? slots.filter {
            $0.roomID == roomID && $0.kinds.contains(kind) && offered(kind, at: $0.id) && (surface == nil || $0.surface == surface)
        } : []
        let position = preferredSlot(kind: kind, among: available, objects: preview, objectID: storedID)
            ?? preferredSlot(kind: kind, among: positions, objects: preview, objectID: storedID)
        let storedItems = preview.filter { item in
            !item.installed && item.roomID == roomID && item.kind == kind && saved.contains { $0.id == item.id }
        }
        let stored = storedID.map { id in storedItems.first { $0.id == id } }
            ?? storedItems.first { $0.slotID == position?.id } ?? storedItems.first
        let atLimit = instance == nil && stored == nil && preview.count >= objectLimit
        let free = atLimit ? 0 : available.count
        let reason: String? = atLimit
            ? "This home has reached its saved-object limit. Bring back an owned object, or discard an unused draft-only trial."
            : position.map { placementReason(preview, roomID: roomID, kind: kind, slotID: $0.id, movingID: stored?.id) }
                ?? (isRetired(kind) ? retiredReason(kind) : "No compatible position is available in this zone.")
        func result(_ status: Availability.Status, _ label: String) -> Availability {
            Availability(status: status, label: label, placed: placed.count, free: free, positions: positions, available: available,
                         position: position, instance: instance, stored: stored, reason: reason)
        }
        if placed.contains(where: { object in !existing.contains { $0.id == object.id && $0.slotID == object.slotID } }) {
            return result(.preview, "In preview")
        }
        if !placed.isEmpty { return result(.placed, placed.count > 1 ? "\(placed.count) placed" : "Placed") }
        if free > 0 { return result(.available, stored != nil ? "In Storage" : existing.isEmpty ? "Available to add" : "Available in preview") }
        return result(.occupied, "Make room first")
    }
}
