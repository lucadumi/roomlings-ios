import Foundation
import RoomlingsCore

/// Room object names, manual states, routines and the default layout, generated from the shared web source
/// (`shared/roomComponents.ts`) by `Scripts/build-room.mjs`.
struct RoomObjectCatalog: Sendable {
    struct Option: Decodable, Hashable, Sendable {
        let id: String
        let name: String
    }

    struct Routine: Decodable, Hashable, Sendable {
        let title: String
        let repeatDays: Int?
    }

    struct Kind: Decodable, Sendable {
        let name: String
        let description: String
        let variants: [Option]
        let states: [Option]
        let chores: [Routine]
    }

    struct Slot: Decodable, Sendable {
        let roomId: String
        let name: String
    }

    private struct File: Decodable {
        let version: Int
        let kinds: [String: Kind]
        let finishes: [String: String]
        let slots: [String: Slot]
        let defaultComponents: [JSONValue]
    }

    let kinds: [String: Kind]
    let finishes: [String: String]
    let slots: [String: Slot]
    let defaults: [RoomObject]

    /// The web's object shortcuts (`src/RoomComponents.tsx`), limited to those with a native destination.
    static let shortcuts: [String: String] = [
        "receipt-book": "Open grocery runs",
        "shopping-bag": "Open shopping list",
        "settlement-envelope": "Open repayments",
        "cleaning-caddy": "Open room chores",
    ]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "objects", withExtension: "json", subdirectory: "RoomRenderer") else {
            throw ChoreCatalog.CatalogError.missingBundle
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let defaults = try file.defaultComponents.map(RoomObject.init)
        guard file.version == 1, !file.kinds.isEmpty, !defaults.isEmpty,
              defaults.allSatisfy({ file.kinds[$0.kind] != nil && file.slots[$0.slotID] != nil }) else {
            throw ChoreCatalog.CatalogError.invalidCatalog
        }
        return Self(kinds: file.kinds, finishes: file.finishes, slots: file.slots, defaults: defaults)
    }

    func modelName(_ object: RoomObject) -> String {
        kinds[object.kind]?.variants.first { $0.id == object.variant }?.name ?? object.variant
    }

    func finishName(_ object: RoomObject) -> String {
        finishes[object.finish] ?? object.finish
    }

    func stateName(_ object: RoomObject) -> String? {
        kinds[object.kind]?.states.first { $0.id == object.state }?.name
    }

    /// The web's `componentDisplayName`: objects that share a name in a room are numbered.
    static func displayName(_ object: RoomObject, among objects: [RoomObject]) -> String {
        let matches = objects.filter { $0.roomID == object.roomID && $0.name == object.name }
        guard matches.contains(where: { $0.id != object.id }) else { return object.name }
        let index = matches.firstIndex { $0.id == object.id }.map { $0 + 1 } ?? matches.count + 1
        return "\(object.name) \(index)"
    }
}
