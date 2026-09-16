import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native chore projection")
struct ChoreModelTests {
    @Test
    func readsTypedFieldsWithoutChangingTheAuthoritativeSnapshot() throws {
        let household = try ChoreFixtures.snapshot(ChoreFixtures.household())
        let chores = try HouseholdChores(household: household)
        let chore = try #require(chores.items.first)
        let completion = try #require(chores.history.first)
        #expect(chore.id == ChoreFixtures.choreID)
        #expect(chore.title == "Clear the sink")
        #expect(chore.notes == "Keep the drain clear.")
        #expect(chore.roomID == "kitchen")
        #expect(chore.area == "sink")
        #expect(chore.componentID == nil)
        #expect(chore.componentName == nil)
        #expect(chore.dueDate == "2026-09-15")
        #expect(chore.repeatDays == 7)
        #expect(chore.rotation == [ChoreFixtures.inactiveID, ChoreFixtures.roommateID, ChoreFixtures.memberID])
        #expect(chore.turn == 0)
        #expect(chore.version == 4)
        #expect(chore.occurrence == 1)
        #expect(chore.createdBy == ChoreFixtures.memberID)
        #expect(chore.createdAt == "2026-09-01T12:00:00.000Z")
        #expect(chore.updatedAt == "2026-09-14T12:00:00Z")
        #expect(!chore.archived)
        #expect(completion.id == ChoreFixtures.completionID)
        #expect(completion.choreID == chore.id)
        #expect(completion.occurrence == 0)
        #expect(completion.resultVersion == 1)
        #expect(completion.dueDate == "2026-09-08")
        #expect(completion.assignedTo == ChoreFixtures.roommateID)
        #expect(completion.completedBy == ChoreFixtures.memberID)
        #expect(completion.completedAt == "2026-09-08T12:00:00.000Z")
        #expect(completion.undoneAt == nil)
        #expect(completion.undoneBy == nil)
        #expect(chores.activeMembers.map(\.id) == [ChoreFixtures.memberID, ChoreFixtures.roommateID])
        #expect(chores.members.last?.inactive == true)
        #expect(chores.assignee(for: chore)?.id == ChoreFixtures.roommateID)
        #expect(!chores.isPaused(chore))
        #expect(household.value == ChoreFixtures.household())
        #expect(household.value["unrecognizedServerField"] == .integer(9_007_199_254_740_993))
    }

    @Test
    func absentChoresAndDocumentedOptionalFieldsHaveOnlyTheirSharedDefaults() throws {
        let legacy = try HouseholdChores(household: ChoreFixtures.snapshot(Fixtures.household))
        #expect(legacy.items.isEmpty)
        #expect(legacy.history.isEmpty)
        #expect(legacy.members.count == 1)
        #expect(legacy.members.first?.inactive == false)
        #expect(legacy.billingTimeZone == "UTC")
        var raw = ChoreFixtures.chore
        for field in ["notes", "turn", "componentId", "componentName"] { raw = ChoreFixtures.removing(field, from: raw) }
        let chores = try ChoreFixtures.projection(items: [raw])
        let chore = try #require(chores.items.first)
        #expect(chore.notes == "")
        #expect(chore.turn == 0)
        #expect(chore.componentID == nil)
        #expect(chore.componentName == nil)
    }

    @Test(arguments: [
        "UTC", "Europe/Rome", "Europe/Bucharest", "America/New_York", "Pacific/Kiritimati",
        "utc", "europe/rome", "us/eastern", "america/argentina/comodrivadavia", "etc/utc", "zulu"
    ])
    func retainsTheHouseholdTimeZoneWithoutUsingDeviceSettings(identifier: String) throws {
        let household = ChoreFixtures.replacing(
            ChoreFixtures.household(), with: ["billingTimeZone": .string(identifier)]
        )
        let snapshot = try ChoreFixtures.snapshot(household)
        let chores = try HouseholdChores(household: snapshot)
        #expect(chores.billingTimeZone == identifier)
        #expect(snapshot.value["billingTimeZone"] == .string(identifier))
    }

    @Test(arguments: [("+01:00", 3_600), ("+01", 3_600), ("-0130", -5_400), ("+23:59", 86_340), ("-23", -82_800)])
    func acceptsSharedFixedOffsetsWithoutFoundationRangeLimits(identifier: String, seconds: Int) throws {
        let household = ChoreFixtures.replacing(ChoreFixtures.household(), with: ["billingTimeZone": .string(identifier)])
        let snapshot = try ChoreFixtures.snapshot(household)
        let chores = try HouseholdChores(household: snapshot)
        #expect(chores.timeZone == .fixedOffset(seconds: seconds))
        #expect(chores.billingTimeZone == identifier)
        #expect(snapshot.value["billingTimeZone"] == .string(identifier))
    }

    @Test
    func caseInsensitiveAliasesKeepTheSameSeasonalOffsets() throws {
        let canonical = try HouseholdTimeZone(identifier: "US/Eastern")
        let folded = try HouseholdTimeZone(identifier: "us/eastern")
        guard case .named(let expected) = canonical, case .named(let actual) = folded else {
            Issue.record("An IANA name must resolve to a named time zone.")
            return
        }
        for date in [Date(timeIntervalSince1970: 1_736_942_400), Date(timeIntervalSince1970: 1_752_580_800)] {
            #expect(actual.secondsFromGMT(for: date) == expected.secondsFromGMT(for: date))
        }
    }

    @Test(arguments: [
        JSONValue.null, .integer(0), .string(""), .string(" UTC "), .string("Mars/Olympus_Mons"),
        .string("+24:00"), .string("-23:60"), .string("+1"), .string("+010"), .string("+01:00:00"),
        .string(String(repeating: "a", count: 101))
    ])
    func malformedTimeZonesNeverFallBackToUTCOrDeviceTime(value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            let household = ChoreFixtures.replacing(ChoreFixtures.household(), with: ["billingTimeZone": value])
            _ = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        }
    }

    @Test(arguments: [
        JSONValue.null, .array([]), .object([:]), .object(["items": .array([])]),
        .object(["items": .array([]), "history": .null])
    ])
    func malformedChoresNeverBecomeAnEmptyBoard(value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            let raw = ChoreFixtures.replacing(ChoreFixtures.household(), with: ["chores": value])
            _ = try HouseholdChores(household: ChoreFixtures.snapshot(raw))
        }
    }

    @Test(arguments: [
        "id", "title", "roomId", "area", "dueDate", "repeatDays", "rotation",
        "createdBy", "createdAt", "updatedAt", "version", "occurrence", "archived"
    ])
    func storedChoresRequireTheirNonOptionalFields(field: String) {
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [ChoreFixtures.removing(field, from: ChoreFixtures.chore)])
        }
    }

    @Test(arguments: [
        ("id", JSONValue.string("not-a-uuid")), ("title", .string(" \n")), ("title", .string(String(repeating: "a", count: 81))),
        ("notes", .null), ("notes", .string(String(repeating: "a", count: 241))), ("turn", .null),
        ("roomId", .string("attic")), ("area", .string("bath")), ("componentId", .string("Not an ID")),
        ("componentName", .null), ("componentName", .string(" ")), ("repeatDays", .integer(0)),
        ("repeatDays", .integer(366)), ("repeatDays", .number(1.5)), ("turn", .integer(-1)), ("turn", .integer(3)),
        ("version", .integer(-1)), ("version", .number(1.5)), ("version", .integer(Int64.max)),
        ("occurrence", .integer(-1)), ("occurrence", .integer(5)), ("archived", .string("false")),
        ("createdBy", .string("not-a-uuid")), ("createdAt", .string("2026-02-30T12:00:00Z")),
        ("updatedAt", .string("2026-09-15T25:00:00Z")), ("updatedAt", .string("2026-09-15")),
        ("dueDate", .null)
    ])
    func rejectsMalformedStoredChoreFields(key: String, value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [ChoreFixtures.replacing(ChoreFixtures.chore, with: [key: value])])
        }
    }

    @Test(arguments: [
        "1899-12-31", "2026-02-29", "1900-02-29", "2100-02-29", "2026-04-31", "2026-00-01", "2026-13-01",
        "2026-01-00", "2026-01-32", "2026-9-15", "26-09-15", "10000-01-01", "2026-09-15T00:00:00Z",
        " 2026-09-15", "2026-09-15\n", "２０２６-０９-１５", ""
    ])
    func rejectsInvalidCalendarDatesInDraftsAndSnapshots(date: String) {
        #expect(throws: AccountError.invalidInput(.dueDate)) {
            try ChoreDraft(title: "Clean", dueDate: date, rotation: [ChoreFixtures.memberID])
        }
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [
                ChoreFixtures.replacing(ChoreFixtures.chore, with: ["dueDate": .string(date)])
            ])
        }
    }

    @Test(arguments: ["1900-01-01", "2000-02-29", "2024-02-29", "2026-03-29", "2026-10-25", "9999-12-31"])
    func acceptsCalendarBoundariesWithoutTimeZoneOrDSTArithmetic(date: String) throws {
        let draft = try ChoreDraft(title: "Clean", dueDate: date, rotation: [ChoreFixtures.memberID])
        #expect(draft.dueDate == date)
        let chore = try #require(ChoreFixtures.projection(items: [
            ChoreFixtures.replacing(ChoreFixtures.chore, with: ["dueDate": .string(date)])
        ]).items.first)
        #expect(chore.dueDate == date)
        #expect(try chore.status(on: date) == .due)
    }

    @Test
    func draftTrimsExactlyLikeSharedStringsAndCountsUTF16Units() throws {
        let draft = try ChoreDraft(
            title: "\u{FEFF}  Clean 🧹 \n", notes: "\u{FEFF}  Notes \u{3000}",
            dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID]
        )
        #expect(draft.title == "Clean 🧹")
        #expect(draft.notes == "Notes")
        #expect(draft.turn == 0)
        #expect(draft.roomID == nil && draft.area == nil && draft.componentID == nil && draft.repeatDays == nil)
        let maximum = try ChoreDraft(
            title: String(repeating: "🧹", count: 40), notes: String(repeating: "🧹", count: 120),
            dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID]
        )
        #expect(maximum.title.utf16.count == 80)
        #expect(maximum.notes.utf16.count == 240)
        #expect(throws: AccountError.invalidInput(.title)) {
            try ChoreDraft(title: String(repeating: "🧹", count: 41), dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID])
        }
        #expect(throws: AccountError.invalidInput(.notes)) {
            try ChoreDraft(
                title: "Clean", notes: String(repeating: "🧹", count: 121),
                dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID]
            )
        }
        let nextLine = try ChoreDraft(title: "\u{0085}", dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID])
        #expect(nextLine.title == "\u{0085}")
    }

    @Test(arguments: [
        (Optional<String>.none, Optional<String>.some("sink"), Optional<String>.none, AccountInputField.area),
        (.some("attic"), .none, .none, .roomID),
        (.some("bathroom"), .some("bins"), .none, .area),
        (.some("kitchen"), .some("plants"), .none, .area),
        (.none, .none, .some("default-kitchen-sink"), .componentID),
        (.some("kitchen"), .none, .some(""), .componentID),
        (.some("kitchen"), .none, .some("-sink"), .componentID),
        (.some("kitchen"), .none, .some("UpperCase"), .componentID),
        (.some("kitchen"), .none, .some("sink/slash"), .componentID),
        (.some("kitchen"), .none, .some(String(repeating: "a", count: 81)), .componentID)
    ])
    func validatesDraftRoomAreaAndSlugComponentIDs(
        roomID: String?, area: String?, componentID: String?, field: AccountInputField
    ) {
        #expect(throws: AccountError.invalidInput(field)) {
            try ChoreDraft(
                title: "Clean", roomID: roomID, area: area, componentID: componentID,
                dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID]
            )
        }
    }

    @Test(arguments: [-1, 0, 366, Int.max])
    func rejectsInvalidRepeatIntervals(days: Int) {
        #expect(throws: AccountError.invalidInput(.repeatDays)) {
            try ChoreDraft(title: "Clean", dueDate: "2026-09-15", repeatDays: days, rotation: [ChoreFixtures.memberID])
        }
    }

    @Test(arguments: [0, 2, 13])
    func rejectsEmptyDuplicateOrOversizedRotations(scenario: Int) {
        let rotation = scenario == 2 ? [ChoreFixtures.memberID, ChoreFixtures.memberID]
            : (0..<scenario).map { _ in UUID() }
        #expect(throws: AccountError.invalidInput(.rotation)) {
            try ChoreDraft(title: "Clean", dueDate: "2026-09-15", rotation: rotation)
        }
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [
                ChoreFixtures.replacing(ChoreFixtures.chore, with: ["rotation": .array(rotation.map(ChoreFixtures.id))])
            ])
        }
    }

    @Test(arguments: [-1, 1, 12, Int.max])
    func turnMustPointInsideItsRotation(turn: Int) {
        #expect(throws: AccountError.invalidInput(.turn)) {
            try ChoreDraft(title: "Clean", dueDate: "2026-09-15", rotation: [ChoreFixtures.memberID], turn: turn)
        }
    }

    @Test
    func assignmentSkipsInactiveMembersAndWrapsWithoutRewritingTheTurn() throws {
        let raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["turn": .integer(2)])
        let chores = try ChoreFixtures.projection(items: [raw])
        let chore = try #require(chores.items.first)
        #expect(chores.assignee(for: chore)?.id == ChoreFixtures.memberID)
        let members = ChoreFixtures.members.map { ChoreFixtures.replacing($0, with: ["inactive": .bool(true)]) }
        let noActive = try HouseholdChores(household: ChoreFixtures.snapshot(
            ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: ["members": .array(members)])
        ))
        #expect(noActive.assignee(for: chore) == nil)
        #expect(chore.turn == 2)
        let onlyAlex = ChoreFixtures.members.map {
            ChoreFixtures.replacing($0, with: ["inactive": .bool($0["id"] != ChoreFixtures.id(ChoreFixtures.roommateID))])
        }
        let wraps = try HouseholdChores(household: ChoreFixtures.snapshot(
            ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: ["members": .array(onlyAlex)])
        ))
        #expect(wraps.assignee(for: chore)?.id == ChoreFixtures.roommateID)
    }

    @Test
    func statusMatchesSharedPrecedenceAndCompletedOneOffDates() throws {
        let oneOff = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["repeatDays": .null, "dueDate": .null])
        let completed = try #require(ChoreFixtures.projection(items: [oneOff]).items.first)
        #expect(try completed.status(on: "2026-09-15") == .completed)
        let archived = try #require(ChoreFixtures.projection(items: [
            ChoreFixtures.replacing(oneOff, with: ["archived": .bool(true)])
        ]).items.first)
        #expect(try archived.status(on: "2026-09-15") == .archived)
        let due = try #require(ChoreFixtures.projection().items.first)
        #expect(try due.status(on: "2026-09-14") == .upcoming)
        #expect(try due.status(on: "2026-09-15") == .due)
        #expect(try due.status(on: "2026-09-16") == .overdue)
        #expect(throws: AccountError.invalidInput(.dueDate)) { try due.status(on: "yesterday") }
    }

    @Test(arguments: [
        "id", "choreId", "occurrence", "title", "roomId", "area", "dueDate", "turn",
        "assignedTo", "completedBy", "completedAt", "resultVersion", "undoneAt", "undoneBy"
    ])
    func completionHistoryDoesNotInventMissingFields(field: String) {
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(history: [ChoreFixtures.removing(field, from: ChoreFixtures.completion)])
        }
    }

    @Test(arguments: [
        ("dueDate", JSONValue.null), ("dueDate", .string("1900-02-29")), ("turn", .integer(12)),
        ("turn", .integer(-1)), ("occurrence", .integer(-1)), ("occurrence", .integer(1)),
        ("resultVersion", .integer(0)), ("resultVersion", .integer(5)),
        ("assignedTo", .string(Fixtures.accountID)), ("completedBy", .string(Fixtures.accountID)),
        ("completedAt", .string("today")), ("undoneAt", .string("2026-09-15T12:00:00Z")),
        ("undoneBy", .string(Fixtures.memberID)), ("choreId", .string(Fixtures.accountID))
    ])
    func rejectsInvalidCompletionHistory(key: String, value: JSONValue) {
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(history: [
                ChoreFixtures.replacing(ChoreFixtures.completion, with: [key: value])
            ])
        }
    }

    @Test
    func undoneOccurrencesCanCoexistButActiveCompletionsAndIDsStayUnique() throws {
        let undone = ChoreFixtures.replacing(ChoreFixtures.completion, with: [
            "id": ChoreFixtures.id(ChoreFixtures.addedID),
            "undoneAt": .string("2026-09-08T12:05:00Z"), "undoneBy": ChoreFixtures.id(ChoreFixtures.roommateID)
        ])
        let chores = try ChoreFixtures.projection(history: [ChoreFixtures.completion, undone])
        #expect(chores.history.count == 2)
        #expect(chores.history.last?.undoneBy == ChoreFixtures.roommateID)
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(history: [ChoreFixtures.completion, ChoreFixtures.completion])
        }
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(history: [
                ChoreFixtures.completion,
                ChoreFixtures.replacing(ChoreFixtures.completion, with: ["id": ChoreFixtures.id(ChoreFixtures.addedID)])
            ])
        }
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [ChoreFixtures.chore, ChoreFixtures.chore])
        }
    }

    @Test(arguments: ["createdBy", "rotation"])
    func referencesMustBelongToRetainedHouseholdMembers(key: String) {
        let unknown = ChoreFixtures.id(UUID(uuidString: Fixtures.accountID)!)
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: [
                ChoreFixtures.replacing(ChoreFixtures.chore, with: [key: key == "rotation" ? .array([unknown]) : unknown])
            ])
        }
    }

    @Test(arguments: [false, true])
    func availabilityFollowsInstalledNotAssignmentOrDueDate(installed: Bool) throws {
        let object = ChoreFixtures.component(installed: installed)
        let raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "roomId": .string("living-room"), "area": .string("plants"),
            "componentId": .string("saved-object"), "componentName": .string("Our plant")
        ])
        let household = ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: ["roomComponents": .array([object])])
        let chores = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        let chore = try #require(chores.items.first)
        #expect(chores.isPaused(chore) == !installed)
        #expect(chore.dueDate == "2026-09-15")
        #expect(chore.turn == 0)
        #expect(chore.componentName == "Our plant")
        let archived = ChoreFixtures.replacing(raw, with: ["archived": .bool(true)])
        let archivedBoard = try HouseholdChores(household: ChoreFixtures.snapshot(
            ChoreFixtures.replacing(household, with: ["chores": .object(["items": .array([archived]), "history": .array([])])])
        ))
        #expect(!archivedBoard.isPaused(try #require(archivedBoard.items.first)))
    }

    @Test
    func movingAnInstalledObjectInsideItsRoomDoesNotPauseItsChores() throws {
        let moved = ChoreFixtures.component(slotID: "living-room-windowsill")
        let raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "roomId": .string("living-room"), "area": .string("plants"), "componentId": .string("saved-object")
        ])
        let household = ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: ["roomComponents": .array([moved])])
        let chores = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        #expect(!chores.isPaused(try #require(chores.items.first)))
    }

    @Test(arguments: ["missing", "room", "area", "malformed-component", "duplicate-component"])
    func objectReferencesAndNeededAvailabilityFieldsAreValidated(scenario: String) {
        var raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: ["componentId": .string("saved-object")])
        var object = ChoreFixtures.component(kind: "sink", roomID: "kitchen", slotID: "kitchen-sink")
        switch scenario {
        case "missing": raw = ChoreFixtures.replacing(raw, with: ["componentId": .string("unknown-object")])
        case "room": raw = ChoreFixtures.replacing(raw, with: ["roomId": .string("bathroom")])
        case "area": raw = ChoreFixtures.replacing(raw, with: ["area": .string("floor")])
        case "malformed-component": object = ChoreFixtures.removing("installed", from: object)
        default: break
        }
        let household = ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: [
            "roomComponents": .array(scenario == "duplicate-component" ? [object, object] : [object])
        ])
        #expect(throws: AccountError.invalidResponse) {
            try HouseholdChores(household: ChoreFixtures.snapshot(household))
        }
    }

    @Test(arguments: [
        ("kitchen", "bread-box", Optional<String>.none),
        ("living-room", "bins", .some("bins"))
    ])
    func sharedRetiredPlacementsArePausedEvenInOldSnapshots(roomID: String, kind: String, area: String?) throws {
        let object = ChoreFixtures.component(kind: kind, roomID: roomID)
        let raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "roomId": .string(roomID), "area": area.map(JSONValue.string) ?? .null,
            "componentId": .string("saved-object")
        ])
        let household = ChoreFixtures.replacing(ChoreFixtures.household(items: [raw]), with: ["roomComponents": .array([object])])
        let snapshot = try ChoreFixtures.snapshot(household)
        let chores = try HouseholdChores(household: snapshot)
        #expect(chores.isPaused(try #require(chores.items.first)))
        #expect(snapshot.value["roomComponents"]?.arrayValue?.first?["installed"] == .bool(true))
    }

    @Test(arguments: [false, true])
    func absentLayoutsAndOldLayoutsUseTheSharedLivingRoomDefaults(savedLayout: Bool) throws {
        let raw = ChoreFixtures.replacing(ChoreFixtures.chore, with: [
            "roomId": .string("living-room"), "area": .string("plants"),
            "componentId": .string("default-living-room-plant")
        ])
        var household = ChoreFixtures.household(items: [raw])
        if savedLayout { household = ChoreFixtures.replacing(household, with: ["roomComponents": .array([])]) }
        let chores = try HouseholdChores(household: ChoreFixtures.snapshot(household))
        #expect(!chores.isPaused(try #require(chores.items.first)))
        let initialized = ChoreFixtures.replacing(household, with: [
            "roomComponents": .array([ChoreFixtures.component(installed: false)])
        ])
        #expect(throws: AccountError.invalidResponse) {
            try HouseholdChores(household: ChoreFixtures.snapshot(initialized))
        }
    }

    @Test
    func collectionAndActiveMemberLimitsAreEnforced() {
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(items: Array(repeating: ChoreFixtures.chore, count: 201))
        }
        #expect(throws: AccountError.invalidResponse) {
            try ChoreFixtures.projection(history: Array(repeating: ChoreFixtures.completion, count: 20_001))
        }
        let members = ChoreFixtures.members + (0..<11).map { index in
            JSONValue.object(["id": ChoreFixtures.id(UUID()), "name": .string("Roommate \(index)"), "color": .string("")])
        }
        #expect(throws: AccountError.invalidResponse) {
            try HouseholdChores(household: ChoreFixtures.snapshot(
                ChoreFixtures.replacing(ChoreFixtures.household(), with: ["members": .array(members)])
            ))
        }
    }
}
