import Foundation
import RoomlingsCore

struct ChoreObject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let roomID: String
    let slotID: String
    let area: String?
    let installed: Bool

    func displayName(in objects: [ChoreObject]) -> String {
        let matches = objects.filter { $0.roomID == roomID && $0.name == name }
        guard matches.contains(where: { $0.id != id }) else { return name }
        let position = matches.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? (matches.count + 1)
        return "\(name) \(position)"
    }
}

struct ChoreCatalog: Decodable, Sendable {
    struct Area: Decodable, Identifiable, Sendable {
        let id: String
        let label: String
    }

    struct Room: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let areas: [Area]
    }

    private struct Component: Decodable, Sendable {
        let id: String
        let name: String
        let kind: String
        let roomID: String
        let slotID: String
        let installed: Bool

        private enum CodingKeys: String, CodingKey {
            case id, name, kind, installed
            case roomID = "roomId"
            case slotID = "slotId"
        }
    }

    private let version: Int
    let rooms: [Room]
    private let componentAreas: [String: [String: String?]]
    private let defaultComponents: [Component]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "chores", withExtension: "json", subdirectory: "RoomRenderer") else {
            throw CatalogError.missingBundle
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == 1, !catalog.rooms.isEmpty,
              Set(catalog.rooms.map(\.id)).count == catalog.rooms.count else {
            throw CatalogError.invalidCatalog
        }
        return catalog
    }

    func objects(in household: HouseholdSnapshot) throws -> [ChoreObject] {
        let components: [Component]
        if let value = household.value["roomComponents"] {
            components = try JSONDecoder().decode([Component].self, from: JSONEncoder().encode(value))
        } else {
            components = defaultComponents
        }
        guard Set(components.map(\.id)).count == components.count else {
            throw CatalogError.invalidObjects
        }
        return try components.map { component in
            guard !component.id.isEmpty, !component.name.isEmpty,
                  rooms.contains(where: { $0.id == component.roomID }),
                  let areas = componentAreas[component.kind], areas.keys.contains(component.roomID) else {
                throw CatalogError.invalidObjects
            }
            return ChoreObject(id: component.id, name: component.name, roomID: component.roomID, slotID: component.slotID,
                               area: areas[component.roomID] ?? nil, installed: component.installed)
        }
    }

    func location(roomID: String?, area: String?, componentName: String? = nil) -> String {
        guard let roomID else { return "Whole home" }
        guard let room = rooms.first(where: { $0.id == roomID }) else { return roomID }
        if let componentName { return "\(room.name): \(componentName)" }
        if let detail = room.areas.first(where: { $0.id == area }) { return "\(room.name): \(detail.label)" }
        return room.name
    }

    enum CatalogError: Error {
        case missingBundle, invalidCatalog, invalidObjects
    }
}
