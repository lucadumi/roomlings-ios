import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Account response validation")
struct ModelTests {
    @Test
    func preservesIntegerJSONIncludingValuesBeyondDoublePrecision() throws {
        let json = Data("""
        {"cents":1999,"large":9007199254740993,"max":9223372036854775807,
         "min":-9223372036854775808,"fraction":1.25,"nested":[true,null,{"cents":45000}]}
        """.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value["cents"] == .integer(1_999))
        #expect(value["large"] == .integer(9_007_199_254_740_993))
        #expect(value["max"] == .integer(Int64.max))
        #expect(value["min"] == .integer(Int64.min))
        #expect(value["fraction"] == .number(1.25))
        #expect(value["nested"] == .array([.bool(true), .null, .object(["cents": .integer(45_000)])]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test(arguments: ["9223372036854775808", "-9223372036854775809", "1e100", "1e999"])
    func rejectsUnrepresentableNumbersInsteadOfRounding(number: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8))
        }
    }

    @Test
    func householdPreservesServerDataAndMetadataWithoutDefaults() throws {
        let data = try Fixtures.data(Fixtures.state(selectedHousehold: true))
        let state = try JSONDecoder().decode(AccountState.self, from: data)
        let household = try #require(state.session?.household)
        #expect(household.id == UUID(uuidString: Fixtures.householdID))
        #expect(household.name == "Our kitchen")
        #expect(household.version == 17)
        #expect(household.currency == .eur)
        #expect(household.value["budget"] == .integer(45_000))
        #expect(household.value["expenses"]?.arrayValue?.first?["amount"] == .integer(1_999))
        #expect(household.value["unrecognizedServerField"] == .integer(9_007_199_254_740_993))
        #expect(household.value["chores"] == nil)
        #expect(household.value["shopping"] == nil)
        #expect(household.value["bills"] == nil)
        let roundTrip = try JSONDecoder().decode(AccountState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip == state)
        #expect(roundTrip.session?.household.value == Fixtures.household)
    }

    @Test
    func explicitSignedOutAndDeletionOnlyStatesAreValid() throws {
        let signedOut = try JSONDecoder().decode(AccountState.self, from: Fixtures.data(Fixtures.state(signedIn: false)))
        #expect(!signedOut.isSignedIn)
        #expect(signedOut.devices.isEmpty)
        #expect(signedOut.session == nil)
        let deleting = try JSONDecoder().decode(
            AccountState.self, from: Fixtures.data(Fixtures.state(deletionPending: true))
        )
        #expect(deleting.isSignedIn)
        #expect(deleting.deletionPending)
        #expect(deleting.memberships.isEmpty)
        #expect(deleting.session == nil)
    }

    @Test(arguments: [
        "configured", "account", "memberships", "devices", "csrfToken", "session"
    ])
    func requiresNullableFieldsToBePresent(field: String) throws {
        var object = Fixtures.state(signedIn: false)
        object.removeValue(forKey: field)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AccountState.self, from: Fixtures.data(object))
        }
    }

    @Test(arguments: [
        "signedOutWithCSRF", "signedOutWithDevices", "signedOutWithMemberships",
        "noCurrentDevice", "twoCurrentDevices", "missingCSRF", "shortCSRF",
        "falseDeletionPending", "nullDeletionPending", "deletingWithHousehold", "signedOutDeleting",
        "duplicateMemberships", "unlinkedHousehold", "unknownMember", "legacySessionToken", "missingSessionToken"
    ])
    func rejectsContradictoryState(scenario: String) throws {
        var object = Fixtures.state(selectedHousehold: true)
        switch scenario {
        case "signedOutWithCSRF":
            object = Fixtures.state(signedIn: false)
            object["csrfToken"] = .string(String(repeating: "c", count: 64))
        case "signedOutWithDevices":
            object = Fixtures.state(signedIn: false)
            object["devices"] = .array([Fixtures.device])
        case "signedOutWithMemberships":
            object = Fixtures.state(signedIn: false)
            object["memberships"] = .array([Fixtures.membership])
        case "noCurrentDevice":
            object["devices"] = .array([replacing(Fixtures.device, key: "current", with: .bool(false))])
        case "twoCurrentDevices":
            object["devices"] = .array([
                Fixtures.device,
                replacing(Fixtures.device, key: "id", with: .string("55555555-5555-4555-8555-555555555555"))
            ])
        case "missingCSRF": object["csrfToken"] = .null
        case "shortCSRF": object["csrfToken"] = .string("short")
        case "falseDeletionPending": object["deletionPending"] = .bool(false)
        case "nullDeletionPending": object["deletionPending"] = .null
        case "deletingWithHousehold": object["deletionPending"] = .bool(true)
        case "signedOutDeleting": object = Fixtures.state(signedIn: false, deletionPending: true)
        case "duplicateMemberships": object["memberships"] = .array([Fixtures.membership, Fixtures.membership])
        case "unlinkedHousehold": object["memberships"] = .array([])
        case "unknownMember":
            object["session"] = replacing(
                object["session"]!, key: "memberId", with: .string("55555555-5555-4555-8555-555555555555")
            )
        case "legacySessionToken":
            object["session"] = replacing(object["session"]!, key: "token", with: .string(Fixtures.oldToken.value))
        case "missingSessionToken":
            object["session"] = replacing(object["session"]!, key: "token", with: nil)
        default: Issue.record("Unknown fixture")
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AccountState.self, from: Fixtures.data(object))
        }
    }

    @Test(arguments: [
        ("id", JSONValue.string("not-a-uuid")), ("name", .string(" ")),
        ("email", .string("not-an-email")), ("createdAt", .string("2026-02-30T12:00:00.000Z")),
        ("createdAt", .string("yesterday"))
    ])
    func rejectsInvalidAccountFields(key: String, value: JSONValue) throws {
        let invalid = replacing(Fixtures.account, key: key, with: value)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(invalid))
        }
    }

    @Test(arguments: [
        ("id", JSONValue.string("not-a-uuid")), ("name", .string(" ")), ("version", .integer(-1)),
        ("version", .number(1.5)), ("currency", .string("XXX")), ("budget", .number(1.5)),
        ("members", .array([])), ("expenses", .null), ("settlements", .object([:])),
        ("shopping", .object(["items": .array([])])), ("chores", .array([]))
    ])
    func rejectsInvalidHouseholdEnvelope(key: String, value: JSONValue) throws {
        let invalid = replacing(Fixtures.household, key: key, with: value)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HouseholdSnapshot.self, from: JSONEncoder().encode(invalid))
        }
    }

    @Test
    func descriptionsAndMirrorsDoNotExposeCredentials() throws {
        let token = Fixtures.oldToken
        var tokenDump = ""
        dump(token, to: &tokenDump)
        #expect(!String(describing: token).contains(token.value))
        #expect(!String(reflecting: token).contains(token.value))
        #expect(!tokenDump.contains(token.value))
        let state = try JSONDecoder().decode(
            AccountState.self, from: Fixtures.data(Fixtures.state(selectedHousehold: true))
        )
        var stateDump = ""
        dump(state, to: &stateDump)
        #expect(!stateDump.contains(String(repeating: "c", count: 64)))
        #expect(!String(reflecting: state).contains("csrfToken"))
        let householdDescription = String(reflecting: state.session?.household)
        #expect(!householdDescription.contains("test-only-invite"))
    }

    @Test(arguments: [
        "", String(repeating: "x", count: 42), String(repeating: "x", count: 44),
        String(repeating: "x", count: 42) + "=", String(repeating: "x", count: 42) + "/",
        String(repeating: "x", count: 42) + "\n"
    ])
    func rejectsInvalidBearerTokens(value: String) {
        #expect(throws: SessionTokenError.self) { try SessionToken(value) }
    }

    private func replacing(_ value: JSONValue, key: String, with replacement: JSONValue?) -> JSONValue {
        guard case .object(var object) = value else { return value }
        object[key] = replacement
        return .object(object)
    }
}
