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
    /// Where and when each chore is due, with the household calendar, so the room shows overdue care
    /// as dirt. Titles, notes and roommates stay native.
    let chores: JSONValue?
    let billingTimeZone: String?
    /// The shared room on screen. The signed-out preview is always the kitchen.
    private(set) var roomID = Self.defaultRoomID

    static let defaultRoomID = "kitchen"
    static let choreCareFields: Set<String> = ["roomId", "area", "componentId", "dueDate", "archived"]
    static let preview = RoomVisualState(householdID: nil, roomStyle: "original", components: nil,
                                         chores: nil, billingTimeZone: nil)

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
        if let board = household.value["chores"] {
            guard let items = board["items"]?.arrayValue else { throw AccountError.invalidResponse }
            chores = .array(try items.map { item in
                guard case .object(let fields) = item else { throw AccountError.invalidResponse }
                return .object(fields.filter { Self.choreCareFields.contains($0.key) })
            })
        } else {
            chores = nil
        }
        if let timeZone = household.value["billingTimeZone"] {
            guard let name = timeZone.stringValue else { throw AccountError.invalidResponse }
            billingTimeZone = name
        } else {
            billingTimeZone = nil
        }
    }

    private init(householdID: String?, roomStyle: String, components: JSONValue?, chores: JSONValue?,
                 billingTimeZone: String?) {
        self.householdID = householdID
        self.roomStyle = roomStyle
        self.components = components
        self.chores = chores
        self.billingTimeZone = billingTimeZone
    }

    /// The same household shown in another shared room.
    func showing(room roomID: String) -> RoomVisualState {
        var state = self
        state.roomID = householdID == nil ? Self.defaultRoomID : roomID
        return state
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
            let roomId: String
            let roomZoom: Double
            let roomComponents: JSONValue?
            let billingTimeZone: String?
            let chores: JSONValue?
            let viewportInsets: RoomViewportInsets
        }
        let message = Message(paused: paused, householdId: householdID, choresEnabled: householdID != nil,
                              shoppingEnabled: householdID != nil, moneyEnabled: householdID != nil,
                              roomStyle: roomStyle, roomId: roomID, roomZoom: roomZoom,
                              roomComponents: components, billingTimeZone: billingTimeZone, chores: chores,
                              viewportInsets: viewportInsets)
        let data = try JSONEncoder().encode(message)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.invalidResponse
        }
        return object
    }
}
