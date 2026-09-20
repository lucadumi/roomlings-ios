import Foundation

public struct NotificationPreferences: Codable, Sendable, Equatable {
    public let chores: Bool
    public let money: Bool

    public init(chores: Bool, money: Bool) {
        self.chores = chores
        self.money = money
    }

    public init(from decoder: any Decoder) throws {
        try self.init(JSONValue(from: decoder))
    }

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        guard Set(fields.object.keys) == ["chores", "money"] else { throw AccountError.invalidResponse }
        chores = try fields.bool("chores")
        money = try fields.bool("money")
    }
}

public struct HouseholdNotificationSettings: Decodable, Sendable, Equatable {
    public let householdID: UUID
    public let memberID: UUID
    public let preferences: NotificationPreferences
    public let pushAvailable: Bool

    public init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        guard Set(fields.object.keys) == ["householdId", "memberId", "preferences", "pushAvailable"] else {
            throw AccountError.invalidResponse
        }
        householdID = try fields.uuid("householdId")
        memberID = try fields.uuid("memberId")
        preferences = try NotificationPreferences(fields.object["preferences"] ?? .null)
        pushAvailable = try fields.bool("pushAvailable")
    }
}

public enum APNsEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct APNsDeviceToken: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(data: Data) throws {
        guard (1...512).contains(data.count) else { throw AccountError.invalidInput(.pushToken) }
        value = data.map { String(format: "%02x", $0) }.joined()
    }

    public init(hex: String) throws {
        let bytes = hex.utf8
        guard (2...1024).contains(bytes.count), bytes.count.isMultiple(of: 2),
              bytes.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { throw AccountError.invalidInput(.pushToken) }
        value = hex.lowercased()
    }

    public var description: String { "APNsDeviceToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

public struct NotificationDestination: Decodable, Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case chores(componentID: String?)
        case expense(UUID)
        case settlement(UUID)
    }

    public let version: Int
    public let householdID: UUID
    public let target: Target

    public init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        version = Int(try fields.integer("version", range: 1...1))
        householdID = try fields.uuid("householdId")
        let keys = Set(fields.object.keys)
        let common: Set<String> = ["version", "kind", "householdId"]
        switch try fields.string("kind") {
        case "chores":
            guard keys == common || keys == common.union(["componentId"]) else {
                throw AccountError.invalidResponse
            }
            let componentID: String?
            if fields.object["componentId"] != nil {
                let value = try fields.string("componentId")
                guard HouseholdValidation.componentID(value) else { throw AccountError.invalidResponse }
                componentID = value
            } else {
                componentID = nil
            }
            target = .chores(componentID: componentID)
        case "expense":
            guard keys == common.union(["expenseId"]) else { throw AccountError.invalidResponse }
            target = .expense(try fields.uuid("expenseId"))
        case "settlement":
            guard keys == common.union(["settlementId"]) else { throw AccountError.invalidResponse }
            target = .settlement(try fields.uuid("settlementId"))
        default:
            throw AccountError.invalidResponse
        }
    }
}
