import Foundation
@testable import RoomlingsCore

enum NotificationFixtures {
    static let householdID = UUID(uuidString: Fixtures.householdID)!
    static let memberID = UUID(uuidString: Fixtures.memberID)!
    static let installationID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    static let expenseID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let settlementID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let preferences = NotificationPreferences(chores: true, money: false)
    static let deviceToken = try! APNsDeviceToken(hex: "0123456789ABCDEF")

    static func settings(pushAvailable: Bool = true) -> [String: JSONValue] {
        [
            "householdId": .string(Fixtures.householdID),
            "memberId": .string(Fixtures.memberID),
            "preferences": .object(["chores": .bool(true), "money": .bool(false)]),
            "pushAvailable": .bool(pushAvailable)
        ]
    }

    static func destination(kind: String = "chores", componentID: String? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "version": .integer(1), "kind": .string(kind), "householdId": .string(Fixtures.householdID)
        ]
        switch kind {
        case "expense": fields["expenseId"] = .string(expenseID.uuidString.lowercased())
        case "settlement": fields["settlementId"] = .string(settlementID.uuidString.lowercased())
        default: break
        }
        if let componentID { fields["componentId"] = .string(componentID) }
        return fields
    }

    static func inactiveState() throws -> [String: JSONValue] {
        var state = Fixtures.state(selectedHousehold: true)
        var selected = try HouseholdFields(state["session"]!).object
        var household = try HouseholdFields(selected["household"]!).object
        var member = try HouseholdFields(household["members"]!.arrayValue!.first!).object
        member["inactive"] = .bool(true)
        household["members"] = .array([.object(member)])
        selected["household"] = .object(household)
        state["session"] = .object(selected)
        return state
    }
}

enum NotificationOperation: String, CaseIterable, Sendable {
    case load, save, register, unregister

    static let settings: [Self] = [.load, .save]
    static let devices: [Self] = [.register, .unregister]

    var method: String {
        switch self {
        case .load: "GET"
        case .save, .register: "PUT"
        case .unregister: "DELETE"
        }
    }

    var path: String {
        switch self {
        case .load, .save: "/api/account/households/\(Fixtures.householdID)/notifications"
        case .register: "/api/account/push-devices"
        case .unregister: "/api/account/push-devices/\(NotificationFixtures.installationID.uuidString.lowercased())"
        }
    }

    var acknowledgment: String { self == .register ? "registered" : "removed" }

    func response() throws -> HTTPResponse {
        let fields = Self.settings.contains(self)
            ? NotificationFixtures.settings()
            : [acknowledgment: JSONValue.bool(true)]
        return try Fixtures.response(fields, path: String(path.dropFirst()))
    }

    @discardableResult
    func perform(
        _ session: AccountSession, householdID: UUID = NotificationFixtures.householdID
    ) async throws -> HouseholdNotificationSettings? {
        switch self {
        case .load:
            return try await session.loadNotificationSettings(householdID: householdID)
        case .save:
            return try await session.saveNotificationSettings(NotificationFixtures.preferences, householdID: householdID)
        case .register:
            try await session.registerPushDevice(
                installationID: NotificationFixtures.installationID,
                token: NotificationFixtures.deviceToken, environment: .sandbox
            )
        case .unregister:
            try await session.unregisterPushDevice(installationID: NotificationFixtures.installationID)
        }
        return nil
    }
}
