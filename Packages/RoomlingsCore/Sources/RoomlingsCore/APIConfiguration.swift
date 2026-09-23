import Foundation

public struct APIConfiguration: Sendable, Equatable {
    public let origin: URL
    public let requestTimeout: TimeInterval

    public init(origin: String, requestTimeout: TimeInterval = 30) throws {
        guard requestTimeout.isFinite, requestTimeout > 0 else { throw AccountError.invalidTimeout }
        guard !origin.contains("\\"),
              origin.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              var components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.percentEncodedHost?.contains("%") == false,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
            throw AccountError.invalidOrigin
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        guard let url = components.url, url.host != nil else { throw AccountError.invalidOrigin }
        self.origin = url
        self.requestTimeout = requestTimeout
    }

    public init(origin: URL, requestTimeout: TimeInterval = 30) throws {
        try self.init(origin: origin.absoluteString, requestTimeout: requestTimeout)
    }

    func url(for endpoint: APIEndpoint) -> URL {
        origin.appendingPathComponent(endpoint.path)
    }

    func contains(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              url.scheme?.lowercased() == origin.scheme?.lowercased(),
              url.host?.lowercased() == origin.host?.lowercased() else { return false }
        return Self.port(for: url) == Self.port(for: origin)
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private static func port(for url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

enum APIEndpoint: Equatable {
    case account, code, verify, recover, logout, deleteAccount
    case createHousehold, acceptInvitation, selectHousehold(UUID)
    case householdInvitations(UUID), createInvitation(UUID), revokeInvitation(UUID, UUID)
    case notificationSettings(UUID), saveNotificationSettings(UUID), registerPushDevice, unregisterPushDevice(UUID)
    case recordAnalytics(UUID)
    case addChore, completeChore(UUID), undoChoreCompletion(UUID)
    case addShoppingItem, editShoppingItem(UUID), removeShoppingItem(UUID), claimShoppingItem(UUID), pickShoppingItem(UUID)
    case recordExpense, removeExpense(UUID), checkoutShopping
    case recordSettlement, removeSettlement(UUID)

    var method: String {
        switch self {
        case .account, .householdInvitations, .notificationSettings: "GET"
        case .saveNotificationSettings, .registerPushDevice: "PUT"
        case .editShoppingItem: "PATCH"
        case .removeShoppingItem, .removeExpense, .removeSettlement, .revokeInvitation, .unregisterPushDevice, .deleteAccount: "DELETE"
        default: "POST"
        }
    }

    var path: String {
        switch self {
        case .account, .deleteAccount: "api/account"
        case .code: "api/account/code"
        case .verify: "api/account/verify"
        case .recover: "api/account/recover"
        case .logout: "api/account/logout"
        case .createHousehold: "api/account/households"
        case .acceptInvitation: "api/account/invitations/accept"
        case .selectHousehold(let id): "api/account/households/\(id.uuidString.lowercased())/select"
        case .householdInvitations(let id): "api/account/households/\(id.uuidString.lowercased())"
        case .createInvitation(let id): "api/account/households/\(id.uuidString.lowercased())/invitations"
        case .revokeInvitation(let household, let invitation):
            "api/account/households/\(household.uuidString.lowercased())/invitations/\(invitation.uuidString.lowercased())"
        case .notificationSettings(let id), .saveNotificationSettings(let id):
            "api/account/households/\(id.uuidString.lowercased())/notifications"
        case .registerPushDevice: "api/account/push-devices"
        case .unregisterPushDevice(let id): "api/account/push-devices/\(id.uuidString.lowercased())"
        case .recordAnalytics(let id): "api/account/households/\(id.uuidString.lowercased())/analytics"
        case .addChore: "api/chores"
        case .completeChore(let id): "api/chores/\(id.uuidString.lowercased())/complete"
        case .undoChoreCompletion(let id): "api/chores/completions/\(id.uuidString.lowercased())/undo"
        case .addShoppingItem: "api/shopping/items"
        case .editShoppingItem(let id), .removeShoppingItem(let id): "api/shopping/items/\(id.uuidString.lowercased())"
        case .claimShoppingItem(let id): "api/shopping/items/\(id.uuidString.lowercased())/claim"
        case .pickShoppingItem(let id): "api/shopping/items/\(id.uuidString.lowercased())/pick"
        case .recordExpense: "api/expenses"
        case .removeExpense(let id): "api/expenses/\(id.uuidString.lowercased())"
        case .checkoutShopping: "api/shopping/checkout"
        case .recordSettlement: "api/settlements"
        case .removeSettlement(let id): "api/settlements/\(id.uuidString.lowercased())"
        }
    }
}
