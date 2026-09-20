import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Notification models and routing")
struct NotificationModelTests {
    @Test
    func preferencesEncodeOnlyTheSharedBooleans() throws {
        let value = NotificationPreferences(chores: false, money: true)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object([
            "chores": .bool(false), "money": .bool(true)
        ]))
        #expect(try JSONDecoder().decode(NotificationPreferences.self, from: data) == value)
    }

    @Test(arguments: ["chores", "money"], ["missing", "null", "string", "integer"])
    func bothPreferencesRequireActualBooleans(field: String, fault: String) throws {
        var fields: [String: JSONValue] = ["chores": .bool(true), "money": .bool(false)]
        switch fault {
        case "missing": fields.removeValue(forKey: field)
        case "null": fields[field] = .null
        case "string": fields[field] = .string("true")
        default: fields[field] = .integer(1)
        }
        #expect(throws: AccountError.invalidResponse) {
            try JSONDecoder().decode(NotificationPreferences.self, from: Fixtures.data(fields))
        }
    }

    @Test(arguments: [true, false])
    func settingsPreserveUnavailableProviderAndDurablePreferences(available: Bool) throws {
        let settings = try JSONDecoder().decode(
            HouseholdNotificationSettings.self, from: Fixtures.data(NotificationFixtures.settings(pushAvailable: available))
        )
        #expect(settings.householdID == NotificationFixtures.householdID)
        #expect(settings.memberID == NotificationFixtures.memberID)
        #expect(settings.preferences == NotificationFixtures.preferences)
        #expect(settings.pushAvailable == available)
    }

    @Test(arguments: ["householdId", "memberId", "preferences", "pushAvailable"], ["missing", "null", "wrong-type"])
    func settingsRequireTheWholeTypedResponse(field: String, fault: String) throws {
        var fields = NotificationFixtures.settings()
        switch fault {
        case "missing": fields.removeValue(forKey: field)
        case "null": fields[field] = .null
        default: fields[field] = .integer(1)
        }
        #expect(throws: AccountError.invalidResponse) {
            try JSONDecoder().decode(HouseholdNotificationSettings.self, from: Fixtures.data(fields))
        }
    }

    @Test(arguments: ["householdId", "memberId"])
    func settingsRejectMalformedIdentities(field: String) throws {
        var fields = NotificationFixtures.settings()
        fields[field] = .string("not-a-uuid")
        #expect(throws: AccountError.invalidResponse) {
            try JSONDecoder().decode(HouseholdNotificationSettings.self, from: Fixtures.data(fields))
        }
    }

    @Test(arguments: ["accessToken", "credential", "token", "session"], [true, false])
    func settingsRejectCredentialExposureAtEitherLevel(field: String, nested: Bool) throws {
        var fields = NotificationFixtures.settings()
        if nested {
            var preferences = try HouseholdFields(fields["preferences"]!).object
            preferences[field] = .string(Fixtures.oldToken.value)
            fields["preferences"] = .object(preferences)
        } else {
            fields[field] = .string(Fixtures.oldToken.value)
        }
        #expect(throws: AccountError.invalidResponse) {
            try JSONDecoder().decode(HouseholdNotificationSettings.self, from: Fixtures.data(fields))
        }
    }

    @Test(arguments: [1, 16, 32, 64, 512])
    func tokensAcceptVariableBinaryLengthsAndCanonicalizeHex(length: Int) throws {
        let data = Data(repeating: 0xab, count: length)
        let binary = try APNsDeviceToken(data: data)
        let hex = try APNsDeviceToken(hex: String(repeating: "Ab", count: length))
        #expect(binary == hex)
        let canonical = hex.value == String(repeating: "ab", count: length)
        #expect(canonical)
    }

    @Test(arguments: [
        "empty", "one-digit", "odd", "too-long", "prefix", "whitespace", "newline", "non-hex", "unicode", "angle-brackets"
    ])
    func invalidHexNeverBecomesARequestToken(fault: String) {
        let hex: String
        switch fault {
        case "empty": hex = ""
        case "one-digit": hex = "a"
        case "odd": hex = "abc"
        case "too-long": hex = String(repeating: "ab", count: 513)
        case "prefix": hex = "0xab"
        case "whitespace": hex = "ab cd"
        case "newline": hex = "ab\n"
        case "non-hex": hex = "gh"
        case "unicode": hex = "ａｂ"
        default: hex = "<abcd>"
        }
        #expect(throws: AccountError.invalidInput(.pushToken)) { try APNsDeviceToken(hex: hex) }
    }

    @Test(arguments: [0, 513])
    func binaryTokensRejectEmptyOrOversizedData(length: Int) {
        #expect(throws: AccountError.invalidInput(.pushToken)) {
            try APNsDeviceToken(data: Data(repeating: 0, count: length))
        }
    }

    @Test
    func tokensRedactDescriptionsDebuggingAndReflection() throws {
        let token = NotificationFixtures.deviceToken
        var dumped = ""
        dump(token, to: &dumped)
        let presentations = [
            String(describing: token), String(reflecting: token), String(reflecting: [token]), dumped,
            Mirror(reflecting: token).children.map { String(describing: $0.value) }.joined()
        ]
        for presentation in presentations {
            #expect(!presentation.contains(token.value))
            #expect(!presentation.contains(token.value.uppercased()))
        }
        #expect(String(describing: token).contains("redacted"))
    }

    @Test(arguments: [APNsEnvironment.sandbox, .production])
    func environmentsUseOnlyTheSharedRawValues(environment: APNsEnvironment) throws {
        let data = try JSONEncoder().encode(environment)
        #expect(try JSONDecoder().decode(String.self, from: data) == environment.rawValue)
        #expect(try JSONDecoder().decode(APNsEnvironment.self, from: data) == environment)
    }

    @Test(arguments: ["development", "Sandbox", "PRODUCTION", ""])
    func unknownAPNsEnvironmentsAreRejected(value: String) throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(APNsEnvironment.self, from: JSONEncoder().encode(value))
        }
    }

    @Test(arguments: ["chores", "expense", "settlement"])
    func customPayloadsProduceOnlyTypedDestinations(kind: String) throws {
        let destination = try decode(NotificationFixtures.destination(kind: kind))
        #expect(destination.version == 1)
        #expect(destination.householdID == NotificationFixtures.householdID)
        switch kind {
        case "expense": #expect(destination.target == .expense(NotificationFixtures.expenseID))
        case "settlement": #expect(destination.target == .settlement(NotificationFixtures.settlementID))
        default: #expect(destination.target == .chores(componentID: nil))
        }
    }

    @Test(arguments: ["kitchen-cabinets", "bedroom-2", "a", String(repeating: "x", count: 80)])
    func objectChoresUseTheSharedComponentSlugValidation(componentID: String) throws {
        let destination = try decode(NotificationFixtures.destination(componentID: componentID))
        #expect(destination.target == NotificationDestination.Target.chores(componentID: componentID))
    }

    @Test(arguments: ["", "-cabinet", "Kitchen", "kitchen_sink", "two words", "a/b", "https://example.com", String(repeating: "x", count: 81)])
    func malformedComponentsCannotBecomeRoutes(componentID: String) {
        #expect(throws: AccountError.invalidResponse) {
            try decode(NotificationFixtures.destination(componentID: componentID))
        }
    }

    @Test(arguments: ["chores", "expense", "settlement"], ["missing-version", "future-version", "boolean-version", "missing-household", "bad-household", "unknown-kind"])
    func genericPayloadsRequireKnownVersionKindAndHousehold(kind: String, fault: String) {
        var payload = NotificationFixtures.destination(kind: kind)
        switch fault {
        case "missing-version": payload.removeValue(forKey: "version")
        case "future-version": payload["version"] = .integer(2)
        case "boolean-version": payload["version"] = .bool(true)
        case "missing-household": payload.removeValue(forKey: "householdId")
        case "bad-household": payload["householdId"] = .string("not-a-uuid")
        default: payload["kind"] = .string("url")
        }
        #expect(throws: AccountError.invalidResponse) { try decode(payload) }
    }

    @Test(arguments: ["expense", "settlement"], ["missing", "null", "string", "number", "other-kind", "component"])
    func moneyRoutesRequireExactlyTheirOwnIdentifier(kind: String, fault: String) {
        var payload = NotificationFixtures.destination(kind: kind)
        let key = kind == "expense" ? "expenseId" : "settlementId"
        switch fault {
        case "missing": payload.removeValue(forKey: key)
        case "null": payload[key] = .null
        case "string": payload[key] = .string("invalid")
        case "number": payload[key] = .integer(42)
        case "other-kind": payload[kind == "expense" ? "settlementId" : "expenseId"] = .string(Fixtures.memberID)
        default: payload["componentId"] = .string("kitchen-cabinets")
        }
        #expect(throws: AccountError.invalidResponse) { try decode(payload) }
    }

    @Test(arguments: ["componentId", "expenseId", "settlementId"])
    func nullOrWrongKindChoreFieldsAreNotOptionalRoutes(field: String) {
        var payload = NotificationFixtures.destination()
        payload[field] = .null
        #expect(throws: AccountError.invalidResponse) { try decode(payload) }
    }

    @Test(arguments: ["url", "route", "targetURL", "accessToken", "credential", "aps", "roomlings"])
    func routingNeverAcceptsUnknownURLsCredentialsOrOuterPayloads(field: String) {
        var payload = NotificationFixtures.destination()
        payload[field] = .string("https://untrusted.example/path")
        #expect(throws: AccountError.invalidResponse) { try decode(payload) }
    }

    @Test
    func callersMustExtractOnlyTheRoomlingsObject() {
        let payload: [String: JSONValue] = [
            "aps": .object(["alert": .string("There is an update in your household.")]),
            "roomlings": .object(NotificationFixtures.destination())
        ]
        #expect(throws: AccountError.invalidResponse) { try decode(payload) }
    }

    private func decode(_ fields: [String: JSONValue]) throws -> NotificationDestination {
        try JSONDecoder().decode(NotificationDestination.self, from: Fixtures.data(fields))
    }
}
