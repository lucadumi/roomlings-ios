import Foundation
@testable import RoomlingsCore

enum ChoreFixtures {
    static let householdID = UUID(uuidString: Fixtures.householdID)!
    static let memberID = UUID(uuidString: Fixtures.memberID)!
    static let roommateID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let inactiveID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let choreID = UUID(uuidString: "aabbccdd-aabb-4ccd-8abb-aabbccddeeff")!
    static let addedID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    static let completionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    static let latestCompletionID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    static let undoMutationID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
    static let mutationID = UUID(uuidString: "ddeeffaa-ddee-4ffa-8dde-aabbccddeeff")!

    static func id(_ id: UUID) -> JSONValue { .string(id.uuidString.lowercased()) }

    static var draft: ChoreDraft {
        try! ChoreDraft(
            title: " Clean the sink ", notes: "\nUse a sponge ",
            roomID: "kitchen", area: "sink", componentID: "default-kitchen-sink",
            dueDate: "2026-09-15", repeatDays: 7, rotation: [memberID, roommateID], turn: 1
        )
    }

    static var members: [JSONValue] {
        [
            .object(["id": id(memberID), "name": .string("Roommate"), "color": .string("#7d9070")]),
            .object(["id": id(roommateID), "name": .string("Alex"), "color": .string("#c9533a"), "inactive": .bool(false)]),
            .object(["id": id(inactiveID), "name": .string("Former roommate"), "color": .string("#7c89a1"), "inactive": .bool(true)])
        ]
    }

    static var chore: JSONValue {
        .object([
            "id": id(choreID), "title": .string("Clear the sink"), "notes": .string("Keep the drain clear."),
            "roomId": .string("kitchen"), "area": .string("sink"), "dueDate": .string("2026-09-15"),
            "repeatDays": .integer(7), "rotation": .array([id(inactiveID), id(roommateID), id(memberID)]),
            "turn": .integer(0), "createdBy": id(memberID), "createdAt": .string("2026-09-01T12:00:00.000Z"),
            "updatedAt": .string("2026-09-14T12:00:00Z"), "version": .integer(4),
            "occurrence": .integer(1), "archived": .bool(false)
        ])
    }

    static var completion: JSONValue {
        .object([
            "id": id(completionID), "choreId": id(choreID), "occurrence": .integer(0),
            "title": .string("Clear the sink"), "roomId": .string("kitchen"), "area": .string("sink"),
            "dueDate": .string("2026-09-08"), "turn": .integer(0), "assignedTo": id(roommateID),
            "completedBy": id(memberID), "completedAt": .string("2026-09-08T12:00:00.000Z"),
            "resultVersion": .integer(1), "undoneAt": .null, "undoneBy": .null
        ])
    }

    static func household(
        items: [JSONValue] = [chore], history: [JSONValue] = [completion], version: Int64 = 17
    ) -> JSONValue {
        replacing(Fixtures.household, with: [
            "members": .array(members), "version": .integer(version),
            "chores": .object(["items": .array(items), "history": .array(history)])
        ])
    }

    static func state(household: JSONValue = household()) -> [String: JSONValue] {
        var state = Fixtures.state(selectedHousehold: true)
        state["session"] = .object(["token": .null, "memberId": id(memberID), "household": household])
        return state
    }

    static func addedHousehold(_ draft: ChoreDraft = draft) -> JSONValue {
        let added = JSONValue.object(draft.requestFields.merging([
            "id": id(addedID), "createdBy": id(memberID), "createdAt": .string("2026-09-15T12:00:00.000Z"),
            "updatedAt": .string("2026-09-15T12:00:00.000Z"), "version": .integer(0),
            "occurrence": .integer(0), "archived": .bool(false)
        ]) { _, value in value })
        return withReceipt(household(items: [chore, added], version: 18))
    }

    static var completedHousehold: JSONValue {
        let updated = replacing(chore, with: [
            "version": .integer(5), "occurrence": .integer(2), "turn": .integer(2),
            "dueDate": .string("2026-09-22"), "updatedAt": .string("2026-09-15T12:00:00.000Z")
        ])
        let finished = replacing(completion, with: [
            "id": id(latestCompletionID),
            "occurrence": .integer(1), "resultVersion": .integer(5), "dueDate": .string("2026-09-15"),
            "completedAt": .string("2026-09-15T12:00:00.000Z")
        ])
        return withReceipt(household(items: [updated], history: [finished, completion], version: 18))
    }

    static var editedHousehold: JSONValue {
        let updated = replacing(chore, with: draft.requestFields.merging([
            "componentName": .string("The sink"),
            "version": .integer(5), "updatedAt": .string("2026-09-15T12:00:00.000Z")
        ]) { _, new in new })
        return withReceipt(household(items: [updated], version: 18))
    }

    static var archivedHousehold: JSONValue {
        withReceipt(household(items: [replacing(chore, with: [
            "archived": .bool(true), "version": .integer(5), "updatedAt": .string("2026-09-15T12:00:00.000Z")
        ])], version: 18))
    }

    static var undoneHousehold: JSONValue {
        guard let finished = completedHousehold["chores"]?["history"]?.arrayValue?.first,
              let receipts = completedHousehold["mutationReceipts"]?.arrayValue else {
            preconditionFailure("The undo fixture needs a recorded completion.")
        }
        let restored = replacing(chore, with: [
            "version": .integer(6), "updatedAt": .string("2026-09-15T12:01:00.000Z")
        ])
        let undone = replacing(finished, with: [
            "undoneAt": .string("2026-09-15T12:01:00.000Z"), "undoneBy": id(memberID)
        ])
        return replacing(completedHousehold, with: [
            "version": .integer(19),
            "chores": .object(["items": .array([restored]), "history": .array([undone, completion])]),
            "mutationReceipts": .array(receipts + [.object([
                "id": id(undoMutationID), "memberId": id(memberID), "version": .integer(19),
                "fingerprint": .string(String(repeating: "2", count: 64))
            ])])
        ])
    }

    static func withReceipt(_ household: JSONValue) -> JSONValue {
        replacing(household, with: [
            "mutationReceipts": .array([.object([
                "id": id(mutationID), "memberId": id(memberID), "version": .integer(18),
                "fingerprint": .string(String(repeating: "1", count: 64))
            ])]),
            "futureServerData": .object(["maximum": .integer(Int64.max), "fraction": .number(1.25)])
        ])
    }

    static func projection(
        items: [JSONValue] = [chore], history: [JSONValue] = [completion]
    ) throws -> HouseholdChores {
        try HouseholdChores(household: snapshot(household(items: items, history: history)))
    }

    static func snapshot(_ value: JSONValue) throws -> HouseholdSnapshot {
        try JSONDecoder().decode(HouseholdSnapshot.self, from: JSONEncoder().encode(value))
    }

    static func replacing(_ value: JSONValue, with changes: [String: JSONValue]) -> JSONValue {
        guard case .object(let object) = value else { preconditionFailure("Expected a test object") }
        return .object(object.merging(changes) { _, new in new })
    }

    static func removing(_ key: String, from value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { preconditionFailure("Expected a test object") }
        object.removeValue(forKey: key)
        return .object(object)
    }

    static func component(
        id: String = "saved-object", kind: String = "plant", roomID: String = "living-room",
        installed: Bool = true, slotID: String = "living-room-plant"
    ) -> JSONValue {
        .object([
            "id": .string(id), "kind": .string(kind), "roomId": .string(roomID),
            "slotId": .string(slotID), "name": .string("Our object"), "variant": .string("original"),
            "finish": .string("room"), "supplies": .array([]), "installed": .bool(installed),
            "version": .integer(1), "state": .null, "stateChangedAt": .null, "stateChangedBy": .null
        ])
    }
}

enum ChoreOperation: CaseIterable, Sendable {
    case add, edit, archive, complete

    var successHousehold: JSONValue {
        switch self {
        case .add: ChoreFixtures.addedHousehold()
        case .edit: ChoreFixtures.editedHousehold
        case .archive: ChoreFixtures.archivedHousehold
        case .complete: ChoreFixtures.completedHousehold
        }
    }

    var path: String {
        switch self {
        case .add: "/api/chores"
        case .edit: "/api/chores/\(ChoreFixtures.choreID.uuidString.lowercased())"
        case .archive: "/api/chores/\(ChoreFixtures.choreID.uuidString.lowercased())/archive"
        case .complete: "/api/chores/\(ChoreFixtures.choreID.uuidString.lowercased())/complete"
        }
    }

    var method: String { self == .edit || self == .archive ? "PATCH" : "POST" }

    @discardableResult
    func perform(
        _ session: AccountSession, householdID: UUID = ChoreFixtures.householdID,
        version: Int64 = 17, mutationID: UUID = ChoreFixtures.mutationID
    ) async throws -> AccountState {
        switch self {
        case .add:
            try await session.addChore(
                ChoreFixtures.draft, householdID: householdID, version: version, mutationID: mutationID
            )
        case .edit:
            try await session.editChore(
                id: ChoreFixtures.choreID, draft: ChoreFixtures.draft, choreVersion: 4,
                householdID: householdID, version: version, mutationID: mutationID
            )
        case .archive:
            try await session.setChoreArchived(
                id: ChoreFixtures.choreID, archived: true, choreVersion: 4,
                householdID: householdID, version: version, mutationID: mutationID
            )
        case .complete:
            try await session.completeChore(
                id: ChoreFixtures.choreID, choreVersion: 4,
                householdID: householdID, version: version, mutationID: mutationID
            )
        }
    }
}
