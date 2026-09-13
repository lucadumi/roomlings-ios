import Foundation
import RoomlingsCore

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

    func message(paused: Bool) throws -> [String: Any] {
        struct Message: Encodable {
            let version = 1
            let type = "state"
            let paused: Bool
            let householdId: String?
            let roomStyle: String
            let roomComponents: JSONValue?
        }
        let message = Message(paused: paused, householdId: householdID, roomStyle: roomStyle, roomComponents: components)
        let data = try JSONEncoder().encode(message)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.invalidResponse
        }
        return object
    }
}
