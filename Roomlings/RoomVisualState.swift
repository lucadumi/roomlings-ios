import Foundation
import RoomlingsCore

struct RoomViewportInsets: Codable, Equatable, Sendable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double

    static let zero = RoomViewportInsets(top: 0, right: 0, bottom: 0, left: 0)
}

struct RoomVisualState: Equatable, Sendable {
    let householdID: String?
    let roomStyle: String
    let components: JSONValue?

    static let preview = RoomVisualState(householdID: nil, roomStyle: "original", components: nil)

    init(household: HouseholdSnapshot) throws {
        householdID = household.id.uuidString.lowercased()
        if let style = household.value["roomStyle"] {
            guard let name = style.stringValue else { throw AccountError.invalidResponse }
            roomStyle = name
        } else {
            roomStyle = "original"
        }
        if let items = household.value["roomComponents"] {
            guard items.arrayValue != nil else { throw AccountError.invalidResponse }
            components = items
        } else {
            components = nil
        }
    }

    private init(householdID: String?, roomStyle: String, components: JSONValue?) {
        self.householdID = householdID
        self.roomStyle = roomStyle
        self.components = components
    }

    func message(paused: Bool, viewportInsets: RoomViewportInsets = .zero, roomZoom: Double = 1) throws -> [String: Any] {
        struct Message: Encodable {
            let version = 1
            let type = "state"
            let paused: Bool
            let householdId: String?
            let choresEnabled: Bool
            let shoppingEnabled: Bool
            let moneyEnabled: Bool
            let roomStyle: String
            let roomZoom: Double
            let roomComponents: JSONValue?
            let viewportInsets: RoomViewportInsets
        }
        let message = Message(paused: paused, householdId: householdID, choresEnabled: householdID != nil,
                              shoppingEnabled: householdID != nil, moneyEnabled: householdID != nil,
                              roomStyle: roomStyle, roomZoom: roomZoom,
                              roomComponents: components, viewportInsets: viewportInsets)
        let data = try JSONEncoder().encode(message)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.invalidResponse
        }
        return object
    }
}
