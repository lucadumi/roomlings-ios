import Foundation

struct NotificationAPI: Sendable {
    let client: NativeAPIClient

    func load(householdID: UUID, memberID: UUID, token: SessionToken) async throws -> HouseholdNotificationSettings {
        let result: HouseholdNotificationSettings = try await client.request(.notificationSettings(householdID), token: token)
        try validate(result, householdID: householdID, memberID: memberID)
        return result
    }

    func save(
        _ preferences: NotificationPreferences, householdID: UUID, memberID: UUID, token: SessionToken
    ) async throws -> HouseholdNotificationSettings {
        let result: HouseholdNotificationSettings = try await client.request(
            .saveNotificationSettings(householdID), body: JSONEncoder().encode(preferences), token: token
        )
        try validate(result, householdID: householdID, memberID: memberID)
        guard result.preferences == preferences else { throw AccountError.invalidResponse }
        return result
    }

    func register(installationID: UUID, token: APNsDeviceToken, environment: APNsEnvironment, credential: SessionToken) async throws {
        let body: [String: String] = [
            "installationId": installationID.uuidString.lowercased(),
            "token": token.value,
            "environment": environment.rawValue
        ]
        let _: PushRegistrationAcknowledgment = try await client.request(
            .registerPushDevice, body: JSONEncoder().encode(body), token: credential
        )
    }

    func unregister(installationID: UUID, token: SessionToken) async throws {
        let _: PushRemovalAcknowledgment = try await client.request(.unregisterPushDevice(installationID), token: token)
    }

    private func validate(_ result: HouseholdNotificationSettings, householdID: UUID, memberID: UUID) throws {
        guard result.householdID == householdID, result.memberID == memberID else {
            throw AccountError.invalidResponse
        }
    }
}

private struct PushRegistrationAcknowledgment: Decodable, Sendable {
    init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        guard Set(fields.object.keys) == ["registered"], try fields.bool("registered") else {
            throw AccountError.invalidResponse
        }
    }
}

private struct PushRemovalAcknowledgment: Decodable, Sendable {
    init(from decoder: any Decoder) throws {
        let fields = try HouseholdFields(JSONValue(from: decoder))
        guard Set(fields.object.keys) == ["removed"], try fields.bool("removed") else {
            throw AccountError.invalidResponse
        }
    }
}
