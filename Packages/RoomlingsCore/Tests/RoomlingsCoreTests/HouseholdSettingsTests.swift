import Foundation
import Testing
@testable import RoomlingsCore

@Suite("House rules", .timeLimit(.minutes(1)))
struct HouseholdSettingsTests {
    private let householdID = UUID(uuidString: Fixtures.householdID)!
    private let mutationID = ShoppingFixtures.mutationID

    @Test
    func savingSendsTheRulesAndRefreshesTheMembershipName() async throws {
        let original = household(empty: true)
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(original, with: [
            "name": .string("Cedar House"), "budget": .integer(52_500), "currency": .string("GBP"), "version": .integer(18),
        ]))
        let (session, transport) = try await make(initial: original, response: saved)
        let draft = try HouseholdSettingsDraft(name: "  Cedar House ", budget: 52_500, currency: .gbp)
        let result = try await session.updateHouseholdSettings(draft, householdID: householdID, version: 17, mutationID: mutationID)

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/household")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object([
            "name": .string("Cedar House"), "budget": .integer(52_500), "currency": .string("GBP"),
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": .string(mutationID.uuidString.lowercased()),
        ]))
        let settings = try HouseholdSettings(household: #require(result.session?.household))
        #expect(settings.name == "Cedar House" && settings.budget == 52_500 && settings.currency == .gbp)
        let membership = try #require(result.memberships.first { $0.householdID == householdID })
        #expect(membership.householdName == "Cedar House")
        #expect(membership.currency == .gbp)
        #expect(membership.role == .owner)
    }

    @Test
    func recordedMoneyLocksTheCurrencyBeforeAnyRequest() async throws {
        let original = ShoppingFixtures.household()
        let settings = try HouseholdSettings(household: ShoppingFixtures.snapshot(original))
        #expect(settings.currencyLocked)
        let (session, transport) = try await make(initial: original, response: original)
        let draft = try HouseholdSettingsDraft(name: "Our kitchen", budget: 45_000, currency: .usd)
        await #expect(throws: AccountError.invalidInput(.currency)) {
            try await session.updateHouseholdSettings(draft, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func monthlyBillsAloneLockTheCurrency() throws {
        let billed = ShoppingFixtures.replacing(household(empty: true), with: ["bills": .array([.object([:])])])
        #expect(try HouseholdSettings(household: ShoppingFixtures.snapshot(billed)).currencyLocked)
        #expect(try !HouseholdSettings(household: ShoppingFixtures.snapshot(household(empty: true))).currencyLocked)
    }

    @Test
    func aResponseThatChangesAnythingElseIsRejected() async throws {
        let original = household(empty: true)
        let saved = ShoppingFixtures.withReceipt(ShoppingFixtures.replacing(original, with: [
            "name": .string("Cedar House"), "version": .integer(18), "inviteCode": .string("changed"),
        ]))
        let (session, _) = try await make(initial: original, response: saved)
        let draft = try HouseholdSettingsDraft(name: "Cedar House", budget: 45_000, currency: .eur)
        await #expect(throws: AccountError.invalidResponse) {
            try await session.updateHouseholdSettings(draft, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await session.state?.session?.household.name == "Our kitchen")
    }

    @Test
    func aConflictKeepsTheOriginalRulesAndIsNotRetried() async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: household(empty: true))),
            try Fixtures.failure(status: 409, code: nil),
        ])
        let session = make(transport)
        try await session.restore()
        let draft = try HouseholdSettingsDraft(name: "Cedar House", budget: 45_000, currency: .eur)
        await #expect(throws: AccountError.server(status: 409, code: nil)) {
            try await session.updateHouseholdSettings(draft, householdID: householdID, version: 17, mutationID: mutationID)
        }
        #expect(await transport.requests.count == 2)
        #expect(await session.state?.session?.household.name == "Our kitchen")
    }

    @Test
    func draftsFollowTheServerLimits() throws {
        #expect(throws: AccountError.invalidInput(.name)) { try HouseholdSettingsDraft(name: "   ", budget: 100, currency: .eur) }
        #expect(throws: AccountError.invalidInput(.name)) {
            try HouseholdSettingsDraft(name: String(repeating: "a", count: 51), budget: 100, currency: .eur)
        }
        #expect(throws: AccountError.invalidInput(.budgetCents)) { try HouseholdSettingsDraft(name: "Home", budget: 0, currency: .eur) }
        #expect(throws: AccountError.invalidInput(.budgetCents)) {
            try HouseholdSettingsDraft(name: "Home", budget: 100_000_001, currency: .eur)
        }
        #expect(try HouseholdSettingsDraft(name: String(repeating: "a", count: 50), budget: 100_000_000, currency: .ron).budget == 100_000_000)
    }

    // MARK: - Fixtures

    private func household(empty: Bool) -> JSONValue {
        let base = ShoppingFixtures.household()
        return empty ? ShoppingFixtures.replacing(base, with: ["expenses": .array([]), "settlements": .array([])]) : base
    }

    private func make(initial: JSONValue, response: JSONValue) async throws -> (AccountSession, TestTransport) {
        let transport = TestTransport(responses: [
            try Fixtures.response(ShoppingFixtures.state(household: initial)),
            try Fixtures.response(["household": response], path: "api/household"),
        ])
        let session = make(transport)
        try await session.restore()
        return (session, transport)
    }

    private func make(_ transport: TestTransport) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}
