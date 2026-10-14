import Foundation

/// The shared house rules: household name, monthly grocery budget and currency.
public struct HouseholdSettings: Sendable, Equatable {
    public let householdVersion: Int64
    public let name: String
    public let budget: Int64
    public let currency: HouseholdCurrency
    /// The server refuses a currency change once any money has been recorded.
    public let currencyLocked: Bool
    public let members: [HouseholdMember]
    /// Everything a settings save must leave untouched.
    let preserved: JSONValue

    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    public init(household: HouseholdSnapshot) throws {
        let fields = try HouseholdFields(household.value)
        householdVersion = household.version
        name = household.name
        currency = household.currency
        budget = try fields.integer("budget", range: 1...100_000_000)
        members = try HouseholdMember.projection(household.value)
        let expenses = try fields.array("expenses")
        let settlements = try fields.array("settlements")
        let bills = household.value["bills"]?.arrayValue ?? []
        currencyLocked = !expenses.isEmpty || !settlements.isEmpty || !bills.isEmpty
        guard case .object(var object) = household.value else { throw AccountError.invalidResponse }
        for key in Self.changedKeys { object[key] = nil }
        preserved = .object(object)
    }

    /// The rule values, ignoring unrelated household changes.
    public func sameRules(as other: HouseholdSettings) -> Bool {
        name == other.name && budget == other.budget && currency == other.currency
    }

    static let changedKeys = ["name", "budget", "currency", "version", "mutationReceipts"]
}

extension HouseholdSettings: HouseholdProjection {
    static let collectionKey = "expenses"
}

public struct HouseholdSettingsDraft: Sendable, Equatable {
    public let name: String
    public let budget: Int64
    public let currency: HouseholdCurrency

    public init(name: String, budget: Int64, currency: HouseholdCurrency) throws {
        guard let name = HouseholdValidation.text(name, length: 1...50) else { throw AccountError.invalidInput(.name) }
        guard (1...100_000_000).contains(budget) else { throw AccountError.invalidInput(.budgetCents) }
        self.name = name
        self.budget = budget
        self.currency = currency
    }

    var requestFields: [String: JSONValue] {
        ["name": .string(name), "budget": .integer(budget), "currency": .string(currency.rawValue)]
    }

    /// The server applies exactly these values and nothing else moves.
    func matches(_ result: HouseholdSettings, from original: HouseholdSettings) -> Bool {
        result.name == name && result.budget == budget && result.currency == currency
            && result.preserved == original.preserved
    }
}

typealias SettingsMutationResponse = HouseholdMutationResponse<HouseholdSettings>

extension AccountAPI {
    func updateHouseholdSettings(
        _ draft: HouseholdSettingsDraft, version: Int64, mutationID: UUID, memberID: UUID,
        settings: HouseholdSettings, token: SessionToken
    ) async throws -> SettingsMutationResponse {
        guard !settings.currencyLocked || draft.currency == settings.currency else {
            throw AccountError.invalidInput(.currency)
        }
        let response: SettingsMutationResponse = try await client.mutation(
            .updateHouseholdSettings, fields: draft.requestFields, version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == settings.householdVersion, draft.matches(response.projection, from: settings) else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}
