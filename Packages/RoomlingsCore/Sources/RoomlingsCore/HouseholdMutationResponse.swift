import Foundation

protocol HouseholdProjection: Sendable {
    static var collectionKey: String { get }
    var activeMembers: [HouseholdMember] { get }
    init(household: HouseholdSnapshot) throws
}

extension HouseholdChores: HouseholdProjection {
    static let collectionKey = "chores"
}

extension HouseholdShopping: HouseholdProjection {
    static let collectionKey = "shopping"
}

struct HouseholdMutationResponse<Projection: HouseholdProjection>: Decodable, Sendable {
    let household: HouseholdSnapshot
    let projection: Projection
    let replayed: Bool

    private enum CodingKeys: String, CodingKey { case household, replayed, accessToken }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.accessToken) else { throw AccountError.invalidResponse }
        household = try container.decode(HouseholdSnapshot.self, forKey: .household)
        guard household.value[Projection.collectionKey] != nil else { throw AccountError.invalidResponse }
        projection = try Projection(household: household)
        if container.contains(.replayed) {
            guard try container.decode(Bool.self, forKey: .replayed) else { throw AccountError.invalidResponse }
            replayed = true
        } else {
            replayed = false
        }
    }
}

typealias ChoreMutationResponse = HouseholdMutationResponse<HouseholdChores>
typealias ShoppingMutationResponse = HouseholdMutationResponse<HouseholdShopping>
