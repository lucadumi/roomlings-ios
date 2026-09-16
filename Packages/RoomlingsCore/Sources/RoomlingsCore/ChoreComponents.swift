import Foundation

/// Only the shared object identity/availability needed to validate chores, never renderer assets.
struct ChoreComponent: Sendable, Equatable {
    let id: String
    let kind: String
    let roomID: String
    let installed: Bool

    var area: String? {
        if roomID == "living-room" {
            if kind == "plant" { return "plants" }
            if ["rug", "vacuum"].contains(kind) { return "floor" }
        }
        if roomID == "bathroom", kind == "bins" { return nil }
        switch kind {
        case "fridge", "sink", "bins", "bath", "toilet", "mirror": return kind
        case "counters", "hob": return "counters"
        case "sofa": return "seating"
        case "coffee-table", "tv", "media-unit", "bookshelf", "floor-lamp": return "surfaces"
        default: return nil
        }
    }

    static func projection(household: JSONValue) throws -> [String: ChoreComponent] {
        let components: [ChoreComponent]
        if let raw = household["roomComponents"] {
            guard let values = raw.arrayValue, values.count <= 160 else { throw AccountError.invalidResponse }
            var parsed = try values.map { value in
                let fields = try ChoreFields(value)
                let id = try fields.string("id")
                let kind = try fields.string("kind")
                let roomID = try fields.string("roomId")
                let installed = try fields.bool("installed")
                guard ChoreValidation.componentID(id), kinds.contains(kind),
                      ChoreValidation.areas[roomID] != nil else { throw AccountError.invalidResponse }
                // getRoomComponents retires these placements into Storage without changing identities.
                return ChoreComponent(
                    id: id, kind: kind, roomID: roomID,
                    installed: installed && kind != "bread-box" && !(kind == "bins" && roomID == "living-room")
                )
            }
            if !parsed.contains(where: { $0.roomID == "living-room" }) {
                parsed += defaults.filter { $0.roomID == "living-room" }
            }
            components = parsed
        } else {
            components = defaults
        }
        guard components.count <= 160 else { throw AccountError.invalidResponse }
        var byID: [String: ChoreComponent] = [:]
        for component in components {
            guard byID.updateValue(component, forKey: component.id) == nil else { throw AccountError.invalidResponse }
        }
        return byID
    }

    // shared/roomComponents.ts defaultRoomComponents and the legacy living-room migration.
    private static let defaults: [ChoreComponent] = {
        let rooms: [(String, [(String, String)])] = [
            ("kitchen", [
                ("fridge", "fridge"), ("sink", "sink"), ("counters", "counters"), ("hob", "hob"),
                ("kettle", "kettle"), ("table", "table"), ("seating", "seating"),
                ("plant-floor", "plant"), ("plant-counter", "plant"), ("rug", "rug"),
                ("clock", "clock"), ("light", "light"), ("curtains", "curtains"),
                ("supply-shelf", "supply-shelf"), ("cleaning-caddy", "cleaning-caddy"),
                ("noticeboard", "noticeboard"), ("receipt-book", "receipt-book"), ("house-pot", "house-pot"),
                ("shopping-bag", "shopping-bag"), ("settlement-envelope", "settlement-envelope")
            ]),
            ("bathroom", [
                ("sink", "sink"), ("mirror", "mirror"), ("toilet", "toilet"), ("bath", "bath"),
                ("supply-shelf", "supply-shelf"), ("cleaning-caddy", "cleaning-caddy")
            ]),
            ("living-room", [
                ("sofa", "sofa"), ("coffee-table", "coffee-table"), ("media-unit", "media-unit"),
                ("tv", "tv"), ("bookshelf", "bookshelf"), ("floor-lamp", "floor-lamp"),
                ("rug", "rug"), ("plant", "plant"), ("curtains", "curtains"),
                ("supply-shelf", "supply-shelf"), ("cleaning-caddy", "cleaning-caddy"), ("table-top", "board-game")
            ])
        ]
        return rooms.flatMap { roomID, entries in
            entries.map { slot, kind in
                ChoreComponent(id: "default-\(roomID)-\(slot)", kind: kind, roomID: roomID, installed: true)
            }
        }
    }()

    private static let kinds: Set<String> = [
        "fridge", "sink", "counters", "hob", "kettle", "table", "seating", "plant", "rug", "clock", "light",
        "supply-shelf", "cleaning-caddy", "noticeboard", "receipt-book", "house-pot", "shopping-bag", "settlement-envelope",
        "dishwasher", "washing-machine", "dryer", "coffee-machine", "grinder", "microwave", "air-fryer", "toaster",
        "water-filter", "dish-rack", "bins", "vacuum", "bath", "toilet", "mirror", "towel-rack", "laundry-basket",
        "drying-rack", "wall-art", "curtains", "soap-dispenser", "shower-shelf", "oven", "blender", "rice-cooker",
        "fruit-bowl", "spice-rack", "bread-box", "knife-block", "cookbook-stand", "paper-towel-holder", "storage-jars",
        "kitchen-cart", "pet-bowls", "speaker", "air-purifier", "watering-can", "tea-set", "bathroom-scales",
        "hair-dryer", "toothbrush-holder", "storage-cabinet", "wall-calendar", "key-hooks", "bath-tray", "bathroom-stool",
        "stand-mixer", "waffle-maker", "kitchen-scale", "cutting-boards", "mug-tree", "cereal-dispenser", "egg-basket",
        "wall-shelf", "ironing-board", "toilet-brush", "shower-squeegee", "tissue-box", "first-aid-kit",
        "reed-diffuser", "board-game", "record-player", "sofa", "coffee-table", "tv", "media-unit", "bookshelf", "floor-lamp"
    ]
}
