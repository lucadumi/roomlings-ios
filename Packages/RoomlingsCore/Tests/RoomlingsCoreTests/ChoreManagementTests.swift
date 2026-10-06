import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Chore editing and archiving", .timeLimit(.minutes(1)))
struct ChoreManagementTests {
    @Test
    func restoringKeepsTheScheduleRotationAndCompletionHistory() async throws {
        let archived = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["archived": .bool(true)])
        let restored = ChoreFixtures.replacing(archived, with: [
            "archived": .bool(false), "version": .integer(5), "updatedAt": .string("2026-09-15T12:00:00.000Z")
        ])
        let response = ChoreFixtures.withReceipt(ChoreFixtures.household(items: [restored], version: 18))
        let (session, transport, _) = try make(initial: ChoreFixtures.household(items: [archived]), response: response)
        let before = try await session.restore()
        let result = try await session.setChoreArchived(
            id: ChoreFixtures.choreID, archived: false, choreVersion: 4,
            householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
        )
        let request = try #require(await transport.requests.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == ChoreOperation.archive.path)
        #expect(body == .object([
            "version": .integer(17), "mutationVersion": .integer(17),
            "mutationId": ChoreFixtures.id(ChoreFixtures.mutationID),
            "choreVersion": .integer(4), "archived": .bool(false)
        ]))
        #expect(result.session?.household.value["chores"]?["items"] == .array([restored]))
        #expect(result.session?.household.value["chores"]?["history"] == before.session?.household.value["chores"]?["history"])
    }

    @Test
    func schedulingAgainEditsACompletedOneOffWithoutRewritingItsHistory() async throws {
        let completed = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["dueDate": .null, "repeatDays": .null])
        let draft = try ChoreDraft(
            title: "Clear the sink", notes: "Keep the drain clear.", roomID: "kitchen", area: "sink",
            dueDate: "2026-09-30", rotation: [ChoreFixtures.memberID]
        )
        let updated = ChoreFixtures.replacing(completed, with: draft.requestFields.merging([
            "version": .integer(5), "updatedAt": .string("2026-09-24T12:00:00.000Z")
        ]) { _, new in new })
        let response = ChoreFixtures.withReceipt(ChoreFixtures.household(items: [updated], version: 18))
        let (session, _, _) = try make(initial: ChoreFixtures.household(items: [completed]), response: response)
        let initial = try await session.restore()
        let before = try HouseholdChores(household: #require(initial.session?.household))
        #expect(before.canScheduleAgain(try #require(before.history.first)))
        let result = try await session.editChore(
            id: ChoreFixtures.choreID, draft: draft, choreVersion: 4,
            householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
        )
        let after = try HouseholdChores(household: #require(result.session?.household))
        #expect(after.items.first?.dueDate == draft.dueDate)
        #expect(after.items.first?.occurrence == before.items.first?.occurrence)
        #expect(after.history == before.history)
        #expect(!after.canScheduleAgain(try #require(after.history.first)))
    }

    @Test
    func editsExplicitlyClearAnObjectLinkAndItsSnapshotName() async throws {
        let linked = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "componentId": .string("default-kitchen-sink"), "componentName": .string("The sink")
        ])
        let draft = try ChoreDraft(title: "A whole-home task", dueDate: "2026-09-30", rotation: [ChoreFixtures.memberID])
        let updated = ChoreFixtures.removing("componentName", from: ChoreFixtures.replacing(linked, with:
            draft.requestFields.merging(["version": .integer(5)]) { _, new in new }
        ))
        let response = ChoreFixtures.withReceipt(ChoreFixtures.household(items: [updated], version: 18))
        let (session, _, _) = try make(initial: ChoreFixtures.household(items: [linked]), response: response)
        try await session.restore()
        let result = try await session.editChore(
            id: ChoreFixtures.choreID, draft: draft, choreVersion: 4,
            householdID: ChoreFixtures.householdID, version: 17, mutationID: ChoreFixtures.mutationID
        )
        let chores = try HouseholdChores(household: #require(result.session?.household))
        #expect(chores.items.first?.componentID == nil)
        #expect(chores.items.first?.componentName == nil)
        #expect(chores.items.first?.roomID == nil)
    }

    @Test(arguments: [ChoreOperation.edit, .archive], [
        "title", "notes", "dueDate", "repeatDays", "rotation", "turn", "archived", "createdAt", "createdBy",
        "occurrence", "version", "history", "other-chore", "missing-receipt", "wrong-receipt"
    ])
    func aFreshSuccessMustConfirmOnlyTheRequestedChange(operation: ChoreOperation, fault: String) async throws {
        var response = operation.successHousehold
        var chore = try #require(response["chores"]?["items"]?.arrayValue?.first)
        var history = [ChoreFixtures.completion]
        switch fault {
        case "title": chore = ChoreFixtures.replacing(chore, with: ["title": .string("Not requested")])
        case "notes": chore = ChoreFixtures.replacing(chore, with: ["notes": .string("Not requested")])
        case "dueDate": chore = ChoreFixtures.replacing(chore, with: ["dueDate": .string("2026-10-01")])
        case "repeatDays": chore = ChoreFixtures.replacing(chore, with: ["repeatDays": .integer(30)])
        case "rotation": chore = ChoreFixtures.replacing(chore, with: [
            "rotation": .array([ChoreFixtures.id(ChoreFixtures.memberID)]), "turn": .integer(0)
        ])
        case "turn": chore = ChoreFixtures.replacing(chore, with: ["turn": .integer(operation == .edit ? 0 : 1)])
        case "archived": chore = ChoreFixtures.replacing(chore, with: ["archived": .bool(operation == .edit)])
        case "createdAt": chore = ChoreFixtures.replacing(chore, with: ["createdAt": .string("2026-09-02T12:00:00Z")])
        case "createdBy": chore = ChoreFixtures.replacing(chore, with: ["createdBy": ChoreFixtures.id(ChoreFixtures.roommateID)])
        case "occurrence": chore = ChoreFixtures.replacing(chore, with: ["occurrence": .integer(2)])
        case "version": chore = ChoreFixtures.replacing(chore, with: ["version": .integer(6)])
        case "history": history = []
        case "missing-receipt": response = ChoreFixtures.removing("mutationReceipts", from: response)
        case "wrong-receipt":
            let receipt = try #require(response["mutationReceipts"]?.arrayValue?.first)
            response = ChoreFixtures.replacing(response, with: ["mutationReceipts": .array([
                ChoreFixtures.replacing(receipt, with: ["id": ChoreFixtures.id(UUID())])
            ])])
        default: break
        }
        let items = fault == "other-chore"
            ? [chore, ChoreFixtures.replacing(chore, with: ["id": ChoreFixtures.id(ChoreFixtures.addedID)])] : [chore]
        response = ChoreFixtures.replacing(response, with: [
            "chores": .object(["items": .array(items), "history": .array(history)])
        ])
        let (session, transport, store) = try make(response: response)
        let before = try await session.restore()
        await #expect(throws: AccountError.invalidResponse) { try await operation.perform(session) }
        #expect(await session.state == before)
        #expect(await store.token == Fixtures.oldToken)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [ChoreOperation.edit, .archive])
    func receiptReplaysCanReturnALaterEditWithoutRollingItBack(operation: ChoreOperation) async throws {
        let later = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "title": .string("A later change"), "archived": .bool(true), "version": .integer(8)
        ])
        let response = ChoreFixtures.withReceipt(ChoreFixtures.household(items: [later], version: 24))
        let (session, _, _) = try make(response: response, replayed: true)
        try await session.restore()
        let result = try await operation.perform(session)
        #expect(result.session?.household.value == response)
    }

    @Test(arguments: [Int64(-1), ChoreValidation.maximumInteger, Int64.max])
    func invalidChoreVersionsAreRejectedBeforeSending(version: Int64) throws {
        for change in [
            ChoreUpdate.edit(ChoreFixtures.choreID, ChoreFixtures.draft, version),
            .archive(ChoreFixtures.choreID, true, version), .archive(ChoreFixtures.choreID, false, version)
        ] {
            #expect(throws: AccountError.invalidInput(.choreVersion)) { try change.requestFields() }
        }
    }

    @Test(arguments: [false, true])
    func storedObjectsBlockEditingAndRestorationWithoutDroppingHistory(archived: Bool) throws {
        let chore = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "componentId": .string("saved-object"), "archived": .bool(archived)
        ])
        let household = ChoreFixtures.replacing(ChoreFixtures.household(items: [chore]), with: [
            "roomComponents": .array([ChoreFixtures.component(kind: "sink", roomID: "kitchen", installed: false, slotID: "kitchen-sink")])
        ])
        let chores = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        let item = try #require(chores.items.first)
        #expect(!chores.canEdit(item))
        #expect(!chores.canRestore(item))
        #expect(chores.history.count == 1)
    }

    private func make(
        initial: JSONValue = ChoreFixtures.household(), response: JSONValue, replayed: Bool = false
    ) throws -> (AccountSession, TestTransport, MemoryTokenStore) {
        var envelope: [String: JSONValue] = ["household": response]
        if replayed { envelope["replayed"] = .bool(true) }
        let transport = TestTransport(responses: [
            try Fixtures.response(ChoreFixtures.state(household: initial)), try Fixtures.response(envelope)
        ])
        let store = MemoryTokenStore(token: Fixtures.oldToken)
        return (AccountSession(configuration: Fixtures.configuration, tokenStore: store, transport: transport), transport, store)
    }
}
