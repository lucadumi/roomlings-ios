import Foundation

/// The shared room looks, generated from the web's room style presets at build time.
struct RoomStyleCatalog: Decodable, Sendable {
    struct Style: Decodable, Identifiable, Equatable, Sendable {
        struct Colors: Decodable, Equatable, Sendable {
            let wall: String
            let floor: String
            let floorAlternate: String
            let fridgeDoor: String
            let cabinetPanel: String
            let counter: String
            let lightWood: String
        }

        let id: String
        let name: String
        let description: String
        let colors: Colors
    }

    private let version: Int
    let styles: [Style]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "room-styles", withExtension: "json", subdirectory: "RoomRenderer") else {
            throw ChoreCatalog.CatalogError.missingBundle
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == 1, !catalog.styles.isEmpty,
              Set(catalog.styles.map(\.id)).count == catalog.styles.count else {
            throw ChoreCatalog.CatalogError.invalidCatalog
        }
        return catalog
    }

    func style(_ id: String) -> Style? { styles.first { $0.id == id } }
}
