import Foundation

/// The shared look the room renderer draws for everyone in the household.
public struct HouseholdRoomStyle: Sendable, Equatable {
    public static let fallback = "original"

    public let householdVersion: Int64
    public let style: String
    public let members: [HouseholdMember]
    /// Everything a room style save must leave untouched.
    let preserved: JSONValue

    public var activeMembers: [HouseholdMember] { members.filter { !$0.inactive } }

    public init(household: HouseholdSnapshot) throws {
        householdVersion = household.version
        members = try HouseholdMember.projection(household.value)
        if let raw = household.value["roomStyle"] {
            guard let style = raw.stringValue, Self.valid(style) else { throw AccountError.invalidResponse }
            self.style = style
        } else {
            style = Self.fallback
        }
        guard case .object(var object) = household.value else { throw AccountError.invalidResponse }
        for key in ["roomStyle", "version", "mutationReceipts"] { object[key] = nil }
        preserved = .object(object)
    }

    static func valid(_ style: String) -> Bool {
        AccountValidation.matches(style, #"^[a-z]{1,32}$"#)
    }
}

extension HouseholdRoomStyle: HouseholdProjection {
    static let collectionKey = "expenses"
}

typealias RoomStyleMutationResponse = HouseholdMutationResponse<HouseholdRoomStyle>

extension AccountAPI {
    func updateRoomStyle(
        _ style: String, version: Int64, mutationID: UUID, memberID: UUID,
        current: HouseholdRoomStyle, token: SessionToken
    ) async throws -> RoomStyleMutationResponse {
        guard HouseholdRoomStyle.valid(style) else { throw AccountError.invalidInput(.roomStyle) }
        let response: RoomStyleMutationResponse = try await client.mutation(
            .updateRoomStyle, fields: ["roomStyle": .string(style)], version: version, mutationID: mutationID, token: token
        )
        try MutationReceipts.confirm(response.household, version: version, mutationID: mutationID, memberID: memberID)
        if !response.replayed {
            guard version == current.householdVersion, response.projection.style == style,
                  response.projection.preserved == current.preserved else {
                throw AccountError.invalidResponse
            }
        }
        return response
    }
}
