import WebKit
import XCTest
import RoomlingsCore
import SwiftUI
import UIKit
@testable import Roomlings

final class RoomBridgeTests: XCTestCase {
    @MainActor
    func testErrorBannersWrapAtAccessibleSizesWithoutGrowingPastTheSheet() {
        let message = String(repeating: "This change could not be saved. Refresh your household before trying again. ", count: 3)
        func measure(_ size: DynamicTypeSize) -> CGSize {
            let controller = UIHostingController(rootView: RoomFeedback(message)
                .environment(\.dynamicTypeSize, size).frame(width: 320))
            return controller.sizeThatFits(in: CGSize(width: 320, height: 3000))
        }
        let standard = measure(.large)
        let accessible = measure(.accessibility5)
        XCTAssertEqual(standard.width, 320, accuracy: 0.5)
        XCTAssertEqual(accessible.width, 320, accuracy: 0.5)
        XCTAssertGreaterThan(accessible.height, standard.height)
        XCTAssertLessThan(accessible.height, 3000)
    }

    @MainActor
    func testFeedbackActionsKeepTheSharedSecondaryStyleAndMinimumTouchHeight() {
        let controller = UIHostingController(rootView: Button("Retry connection") {}
            .buttonStyle(RoomButtonStyle(kind: .secondary)).frame(width: 250))
        let size = controller.sizeThatFits(in: CGSize(width: 250, height: 1000))
        XCTAssertEqual(size.width, 250, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.height, 44)
    }

    @MainActor
    func testPortraitRoomFramingUsesTheFullWebViewportIncludingSafeAreas() throws {
        let full = try RoomPreviewScreen.roomZoom(for: CGSize(width: 402, height: 874))
        let measured = try RoomPreviewScreen.roomZoom(
            for: CGSize(width: 402, height: 778),
            safeAreaInsets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        )
        XCTAssertEqual(measured, full, accuracy: 0.000_001)
        XCTAssertEqual(measured, 0.60, accuracy: 0.005)
        XCTAssertNotEqual(measured, try RoomPreviewScreen.roomZoom(for: CGSize(width: 402, height: 778)))
    }

    @MainActor
    func testRoomFramingRecomputesAcrossRotationWithoutDeviceCategories() throws {
        let portrait = try RoomPreviewScreen.roomZoom(for: CGSize(width: 402, height: 874))
        let landscape = try RoomPreviewScreen.roomZoom(
            for: CGSize(width: 750, height: 381),
            safeAreaInsets: EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        )
        let returned = try RoomPreviewScreen.roomZoom(
            for: CGSize(width: 402, height: 778),
            safeAreaInsets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        )
        XCTAssertEqual(landscape, 1)
        XCTAssertLessThan(portrait, landscape)
        XCTAssertEqual(returned, portrait, accuracy: 0.000_001)
        XCTAssertEqual(try RoomPreviewScreen.roomZoom(for: CGSize(width: 834, height: 1194)), 0.91, accuracy: 0.005)
        XCTAssertEqual(try RoomPreviewScreen.roomZoom(for: CGSize(width: 1194, height: 834)), 1)
    }

    @MainActor
    func testNarrowWindowsUseAContinuousClampedRoomScale() throws {
        let narrow = try RoomPreviewScreen.roomZoom(for: CGSize(width: 320, height: 1194))
        let wider = try RoomPreviewScreen.roomZoom(for: CGSize(width: 500, height: 1194))
        XCTAssertEqual(narrow, Double(320.0 / 1194.0) / 0.767, accuracy: 0.000_001)
        XCTAssertGreaterThan(wider, narrow)
        XCTAssertEqual(try RoomPreviewScreen.roomZoom(for: CGSize(width: 200, height: 1194)), 0.3)
        XCTAssertEqual(try RoomPreviewScreen.roomZoom(for: CGSize(width: 1194, height: 200)), 1)
        XCTAssertEqual(
            try RoomPreviewScreen.roomZoom(for: CGSize(width: 640, height: 2388)), narrow, accuracy: 0.000_001
        )
    }

    @MainActor
    func testInvalidViewportMeasurementsAreNotReportedAsDefaultZoom() {
        for size in [
            CGSize.zero, CGSize(width: 402, height: 0), CGSize(width: -1, height: 874),
            CGSize(width: CGFloat.infinity, height: 874), CGSize(width: 402, height: CGFloat.nan)
        ] {
            XCTAssertThrowsError(try RoomPreviewScreen.roomZoom(for: size))
        }
        for insets in [
            EdgeInsets(top: -1, leading: 0, bottom: 0, trailing: 0),
            EdgeInsets(top: 0, leading: .infinity, bottom: 0, trailing: 0),
            EdgeInsets(top: 0, leading: 0, bottom: .nan, trailing: 0)
        ] {
            XCTAssertThrowsError(try RoomPreviewScreen.roomZoom(for: CGSize(width: 402, height: 874), safeAreaInsets: insets))
        }
        XCTAssertThrowsError(try RoomPreviewScreen.roomZoom(
            for: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 874),
            safeAreaInsets: EdgeInsets(top: 0, leading: .greatestFiniteMagnitude, bottom: 0, trailing: 0)
        ))
    }

    func testTheWebFontFamiliesAreRegisteredNatively() {
        XCTAssertNotNil(UIFont(name: "DMSans-9ptRegular_Regular", size: 16))
        XCTAssertNotNil(UIFont(name: "Baloo2-SemiBold", size: 26))
        let logo = Bundle.main.url(forResource: "roomlings-loader", withExtension: "png", subdirectory: "RoomRenderer")
            .flatMap { UIImage(contentsOfFile: $0.path) }
        XCTAssertNotNil(logo)
        XCTAssertEqual(logo?.size.width, 256)
        XCTAssertEqual(logo?.size.height, 256)
    }

    func testBudgetInputKeepsExactIntegerCents() {
        XCTAssertEqual(BudgetInput.cents("300"), 30_000)
        XCTAssertEqual(BudgetInput.cents("12.35"), 1_235)
        XCTAssertEqual(BudgetInput.cents("12,35"), 1_235)
        XCTAssertEqual(BudgetInput.cents(".5"), 50)
        XCTAssertEqual(BudgetInput.cents("0.01"), 1)
        XCTAssertEqual(BudgetInput.cents("1000000"), 100_000_000)
        for invalid in ["", "0", "-1", "1.234", "1,000.00", "1000000.01", "999999999999999999999", "."] {
            XCTAssertNil(BudgetInput.cents(invalid), invalid)
        }
    }

    func testRoomMessagesContainOnlyVisualState() throws {
        let householdID = UUID().uuidString.lowercased()
        let memberID = UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": householdID, "name": "Our home", "version": 4, "currency": "EUR",
            "budget": 25_000, "inviteCode": "private-invitation", "roomStyle": "clay",
            "members": [["id": memberID, "name": "Ada", "color": "#81b29a"]],
            "expenses": [], "settlements": [], "roomComponents": [], "billingTimeZone": "Europe/Berlin",
            "chores": ["history": [], "items": [[
                "id": UUID().uuidString.lowercased(), "title": "Private chore title", "notes": "Private chore notes",
                "roomId": "kitchen", "area": "sink", "componentId": "default-kitchen-sink", "componentName": "Private sink",
                "dueDate": "2026-10-01", "repeatDays": 7, "rotation": [memberID], "turn": 0, "createdBy": memberID,
                "createdAt": "2026-09-01T08:00:00.000Z", "updatedAt": "2026-09-01T08:00:00.000Z",
                "version": 1, "occurrence": 0, "archived": false,
            ]]],
        ])
        let household = try JSONDecoder().decode(HouseholdSnapshot.self, from: data)
        let visual = try RoomVisualState(household: household)
        let insets = RoomViewportInsets(top: 150, right: 12, bottom: 34, left: 12)
        let message = try visual.message(paused: true, viewportInsets: insets, roomZoom: 1.35)
        XCTAssertEqual(Set(message.keys), ["version", "type", "paused", "householdId", "choresEnabled", "shoppingEnabled", "moneyEnabled", "roomStyle", "roomId", "roomZoom", "roomComponents", "editMode", "billingTimeZone", "chores", "viewportInsets"])
        XCTAssertEqual(message["roomId"] as? String, "kitchen")
        XCTAssertEqual(message["billingTimeZone"] as? String, "Europe/Berlin")
        let care = try XCTUnwrap(message["chores"] as? [[String: Any]])
        XCTAssertEqual(care.count, 1)
        XCTAssertEqual(Set(care[0].keys), ["roomId", "area", "componentId", "dueDate", "archived"])
        XCTAssertEqual(care[0]["dueDate"] as? String, "2026-10-01")
        XCTAssertEqual(care[0]["componentId"] as? String, "default-kitchen-sink")
        let bathroom = try visual.showing(room: "bathroom").message(paused: false)
        XCTAssertEqual(bathroom["roomId"] as? String, "bathroom")
        XCTAssertEqual((message["viewportInsets"] as? [String: Double])?["top"], 150)
        XCTAssertEqual(message["householdId"] as? String, householdID)
        XCTAssertEqual(message["roomStyle"] as? String, "clay")
        XCTAssertEqual(message["paused"] as? Bool, true)
        XCTAssertEqual(message["choresEnabled"] as? Bool, true)
        XCTAssertEqual(message["shoppingEnabled"] as? Bool, true)
        XCTAssertEqual(message["moneyEnabled"] as? Bool, true)
        XCTAssertEqual(message["roomZoom"] as? Double, 1.35)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        for privateValue in ["private-invitation", "Ada", memberID, "budget", "expenses", "accessToken", "csrfToken",
                             "Private chore title", "Private chore notes", "Private sink", "rotation"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        let preview = try RoomVisualState.preview.message(paused: false)
        XCTAssertNil(preview["householdId"])
        XCTAssertNil(preview["roomComponents"])
        XCTAssertNil(preview["chores"])
        XCTAssertNil(preview["billingTimeZone"])
        XCTAssertEqual(preview["choresEnabled"] as? Bool, false)
        XCTAssertEqual(preview["shoppingEnabled"] as? Bool, false)
        XCTAssertEqual(preview["moneyEnabled"] as? Bool, false)
        XCTAssertEqual(preview["roomZoom"] as? Double, 1)
        let signedOut = try RoomVisualState.preview.showing(room: "bathroom").message(paused: false)
        XCTAssertEqual(signedOut["roomId"] as? String, "kitchen", "The signed-out preview stays in the kitchen.")
        XCTAssertEqual(message["editMode"] as? Bool, false)
        // The room editor's draft replaces the saved objects on this device only, with the previewed object.
        let draft: JSONValue = .array([.object(["id": .string("kettle")])])
        let editing = try visual.editing(draft, placementID: "kettle").message(paused: false)
        XCTAssertEqual(editing["editMode"] as? Bool, true)
        XCTAssertEqual(editing["placementPreviewId"] as? String, "kettle")
        XCTAssertEqual((editing["roomComponents"] as? [[String: Any]])?.first?["id"] as? String, "kettle")
        XCTAssertEqual(try RoomVisualState.preview.editing(draft, placementID: nil).message(paused: false)["editMode"] as? Bool, false)
    }

    func testOnlyKnownStatusMessagesAreAccepted() throws {
        let message = try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "ready"])
        XCTAssertEqual(message.event, .status(.ready))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 2, "type": "status", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": true, "type": "status", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "request", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "unknown"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "ready", "url": "https://example.com"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status"]))
    }

    func testChoreActionsContainOnlyTheHouseholdIdentity() throws {
        let householdID = UUID()
        let message = try RoomBridgeMessage.decode([
            "version": 1, "type": "open-chores", "householdId": householdID.uuidString.lowercased(),
        ])
        XCTAssertEqual(message.event, .openChores(householdID: householdID))
        let object = try RoomBridgeMessage.decode([
            "version": 1, "type": "open-chores", "householdId": householdID.uuidString,
            "componentId": "default-kitchen-sink",
        ])
        XCTAssertEqual(object.event, .openChores(householdID: householdID, componentID: "default-kitchen-sink"))
        let shopping = try RoomBridgeMessage.decode([
            "version": 1, "type": "open-shopping", "householdId": householdID.uuidString,
        ])
        XCTAssertEqual(shopping.event, .openShopping(householdID: householdID))
        let money = try RoomBridgeMessage.decode([
            "version": 1, "type": "open-money", "householdId": householdID.uuidString,
        ])
        XCTAssertEqual(money.event, .openMoney(householdID: householdID))
        let invalidMessages: [[String: Any]] = [
            ["version": 2, "type": "open-chores", "householdId": householdID.uuidString],
            ["version": true, "type": "open-chores", "householdId": householdID.uuidString],
            ["version": 1, "type": "open-chores", "householdId": "another-household"],
            ["version": 1, "type": "open-chores", "householdId": NSNull()],
            ["version": 1, "type": "open-chores"],
            ["version": 1, "type": "open-checkout", "householdId": householdID.uuidString],
            ["version": 1, "type": "open-shopping", "householdId": "unknown"],
            ["version": 1, "type": "open-shopping", "householdId": householdID.uuidString, "componentId": "default-kitchen-fridge"],
            ["version": 1, "type": "open-shopping", "householdId": householdID.uuidString, "accessToken": "not-allowed"],
            ["version": 1, "type": "open-shopping"],
            ["version": true, "type": "open-shopping", "householdId": householdID.uuidString],
            ["version": 1, "type": "open-money", "householdId": "unknown"],
            ["version": 1, "type": "open-money", "householdId": householdID.uuidString, "componentId": "default-kitchen-fridge"],
            ["version": 1, "type": "open-money", "householdId": householdID.uuidString, "accessToken": "not-allowed"],
            ["version": 1, "type": "open-money"],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString, "url": "https://example.com"],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString, "componentId": ""],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString, "componentId": NSNull()],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString, "componentId": true],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString, "componentId": String(repeating: "x", count: 101)],
            ["version": 1, "type": "open-chores", "householdId": householdID.uuidString,
             "componentId": "default-kitchen-sink", "choreId": UUID().uuidString],
        ]
        for invalid in invalidMessages {
            XCTAssertThrowsError(try RoomBridgeMessage.decode(invalid))
        }
    }

    func testChoreCatalogUsesTheSharedRoomAndObjectDefinitions() throws {
        let catalog = try ChoreCatalog.load()
        XCTAssertEqual(catalog.rooms.map(\.name), ["Kitchen", "Bathroom", "Living room"])
        XCTAssertEqual(catalog.location(roomID: "kitchen", area: "sink"), "Kitchen: Sink and dishes")
        XCTAssertEqual(catalog.location(roomID: nil, area: nil), "Whole home")
        let objects = try catalog.objects(in: choreHousehold())
        XCTAssertTrue(objects.contains { $0.slotID == "kitchen-sink" && $0.area == "sink" })
        XCTAssertTrue(objects.contains { $0.roomID == "living-room" && $0.area == "plants" })
        let first = ChoreObject(id: "first", name: "Fern", roomID: "living-room", slotID: "one", area: "plants", installed: true)
        let second = ChoreObject(id: "second", name: "Fern", roomID: "living-room", slotID: "two", area: "plants", installed: true)
        XCTAssertEqual(first.displayName(in: [first, second]), "Fern 1")
        XCTAssertEqual(second.displayName(in: [first, second]), "Fern 2")
        XCTAssertEqual(first.displayName(in: [first]), "Fern")
        let malformed = try choreHousehold(extra: ["roomComponents": [[
            "id": "unknown-object", "name": "Unknown", "kind": "not-a-shared-object",
            "roomId": "kitchen", "slotId": "kitchen-counters", "installed": true,
        ]]])
        XCTAssertThrowsError(try catalog.objects(in: malformed))
    }

    func testChoreDatesUseTheHouseholdTimeZoneAndSharedScheduleLabels() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T00:30:00Z"))
        let calendar = try ChoreCalendar(chores: HouseholdChores(household: choreHousehold(extra: ["billingTimeZone": "Pacific/Honolulu"])))
        XCTAssertEqual(calendar.day(date), "2026-09-14")
        XCTAssertEqual(calendar.completionDay("2026-09-15T00:30:00.000Z"), "2026-09-14")
        XCTAssertEqual(try ChoreCalendar(chores: HouseholdChores(household: choreHousehold())).day(date), "2026-09-15")
        for (identifier, day) in [("europe/rome", "2026-09-15"), ("us/eastern", "2026-09-14"),
                                  ("+01:00", "2026-09-15"), ("+23:59", "2026-09-16"), ("-23:59", "2026-09-14")] {
            let calendar = try ChoreCalendar(chores: HouseholdChores(
                household: choreHousehold(extra: ["billingTimeZone": identifier])
            ))
            XCTAssertEqual(calendar.day(date), day, identifier)
            XCTAssertEqual(calendar.instant(fromPickerDate: calendar.pickerDate(date)), date)
        }
        XCTAssertEqual(ChoreCalendar.title("2026-09-14", today: "2026-09-15"), "Yesterday")
        XCTAssertEqual(ChoreCalendar.title("2026-09-15", today: "2026-09-15"), "Today")
        XCTAssertEqual(ChoreCalendar.repeats(nil), "One-off")
        XCTAssertEqual(ChoreCalendar.repeats(1), "Daily")
        XCTAssertEqual(ChoreCalendar.repeats(7), "Weekly")
        XCTAssertEqual(ChoreCalendar.repeats(14), "Every 2 weeks")
        XCTAssertEqual(ChoreCalendar.repeats(3), "Every 3 days")
        XCTAssertThrowsError(try ChoreCalendar(chores: HouseholdChores(
            household: choreHousehold(extra: ["billingTimeZone": "Not/A-Time-Zone"])
        )))
    }

    func testChoreFormValuesKeepTheNextTurnSafeWhenRotationIndexesFallOutOfRange() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(ChoreFormValues.nextMemberID(in: [first, second], turn: 0), first)
        XCTAssertEqual(ChoreFormValues.nextMemberID(in: [first, second], turn: 1), second)
        XCTAssertEqual(ChoreFormValues.nextMemberID(in: [first, second], turn: 99), first)
        XCTAssertNil(ChoreFormValues.nextMemberID(in: [], turn: 0))
    }

    func testSavedChoreDaysRoundTripThroughTheHouseholdPickerWithoutChangingDates() throws {
        for zone in ["UTC", "us/eastern", "Pacific/Honolulu", "Asia/Kathmandu", "+23:59", "-23:59"] {
            let calendar = try ChoreCalendar(chores: HouseholdChores(household: choreHousehold(extra: ["billingTimeZone": zone])))
            for day in ["1900-01-01", "2026-03-08", "2026-11-01", "2026-09-24"] {
                XCTAssertEqual(calendar.day(try calendar.instant(on: day)), day, zone)
            }
            XCTAssertThrowsError(try calendar.instant(on: "2026-02-30"))
            XCTAssertThrowsError(try calendar.instant(on: "not-a-date"))
        }
    }

    func testChoreEditDraftPreservesSavedFieldsAndSchedulesCompletedOneOffsForToday() throws {
        let memberID = UUID(), formerID = UUID()
        var item: [String: Any] = [
            "id": UUID().uuidString, "title": "Polish the mirror", "notes": "Use the soft cloth.",
            "roomId": "bathroom", "area": "mirror", "componentId": "default-bathroom-mirror",
            "componentName": "Mirror", "dueDate": "2026-11-01", "repeatDays": 9,
            "rotation": [formerID.uuidString, memberID.uuidString], "turn": 1,
            "createdBy": memberID.uuidString, "createdAt": "2026-09-01T12:00:00Z",
            "updatedAt": "2026-09-15T12:00:00Z", "version": 4, "occurrence": 1, "archived": false
        ]
        let members: [[String: Any]] = [
            ["id": memberID.uuidString, "name": "Ada", "color": "#81b29a"],
            ["id": formerID.uuidString, "name": "Former roommate", "color": "#81b29a", "inactive": true]
        ]
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T00:30:00Z"))
        for (days, choice) in [(nil, ""), (1, "1"), (7, "7"), (14, "14"), (9, "custom"), (365, "custom")] as [(Int?, String)] {
            item["repeatDays"] = days.map { $0 as Any } ?? NSNull()
            let chores = try HouseholdChores(household: choreHousehold(extra: [
                "members": members, "billingTimeZone": "us/eastern", "chores": ["items": [item], "history": []]
            ]))
            let calendar = try ChoreCalendar(chores: chores)
            let draft = try ChoreFormValues(chore: XCTUnwrap(chores.items.first), calendar: calendar, now: now)
            XCTAssertEqual(draft.title, "Polish the mirror")
            XCTAssertEqual(draft.notes, "Use the soft cloth.")
            XCTAssertEqual(draft.roomID, "bathroom")
            XCTAssertEqual(draft.area, "mirror")
            XCTAssertEqual(draft.componentID, "default-bathroom-mirror")
            XCTAssertEqual(calendar.day(draft.dueDate), "2026-11-01")
            XCTAssertEqual(draft.repeatChoice, choice)
            XCTAssertEqual(draft.customDays, String(days ?? 3))
            XCTAssertEqual(draft.rotation, [formerID, memberID])
            XCTAssertEqual(draft.nextMemberID, memberID)
        }
        item["dueDate"] = NSNull()
        item["repeatDays"] = NSNull()
        let chores = try HouseholdChores(household: choreHousehold(extra: [
            "members": members, "billingTimeZone": "us/eastern", "chores": ["items": [item], "history": []]
        ]))
        let calendar = try ChoreCalendar(chores: chores)
        let draft = try ChoreFormValues(chore: XCTUnwrap(chores.items.first), calendar: calendar, now: now)
        XCTAssertEqual(calendar.day(draft.dueDate), "2026-09-23")
        XCTAssertEqual(draft.repeatChoice, "")
    }

    private func choreHousehold(extra: [String: Any] = [:]) throws -> HouseholdSnapshot {
        var fields: [String: Any] = [
            "id": UUID().uuidString, "name": "Our home", "version": 4, "currency": "EUR",
            "budget": 25_000, "inviteCode": "test-only-invitation",
            "members": [["id": UUID().uuidString, "name": "Ada", "color": "#81b29a"]],
            "expenses": [], "settlements": [],
        ]
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(HouseholdSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @MainActor
    func testTheRoomReloadsOnceAfterTheRendererStopsButNotInALoop() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var recovery = RoomRecovery()
        XCTAssertTrue(recovery.shouldReload(at: start))
        XCTAssertFalse(recovery.shouldReload(at: start.addingTimeInterval(5)),
                       "A renderer that stops again straight away must show the manual reload.")
        XCTAssertFalse(recovery.shouldReload(at: start.addingTimeInterval(RoomRecovery.interval - 1)))
        XCTAssertTrue(recovery.shouldReload(at: start.addingTimeInterval(RoomRecovery.interval)))
    }

    @MainActor
    func testATerminatedRendererReloadsTheBundledRoomBeforeReportingAFailure() throws {
        var events: [RoomRenderEvent] = []
        let coordinator = RoomWebView.Coordinator(paused: true) { events.append($0) }
        let webView = WKWebView()
        let index = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "RoomRenderer"))
        coordinator.webView = webView
        coordinator.index = index
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.now = { clock }

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(events.isEmpty, "The first termination recovers without an error.")
        XCTAssertEqual(webView.url?.standardizedFileURL, index.standardizedFileURL)

        clock.addTimeInterval(1)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(events, [.failure("The room renderer stopped. Reload the room to continue.")])

        coordinator.invalidate()
        clock.addTimeInterval(RoomRecovery.interval)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(events.count, 1, "A dismantled room neither reloads nor reports.")
    }

    @MainActor
    func testNavigationIsRestrictedToTheBundledEntry() {
        let index = URL(fileURLWithPath: "/app/RoomRenderer/index.html")
        XCTAssertTrue(RoomWebView.Coordinator.allows(index, index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(string: "https://example.com"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(fileURLWithPath: "/app/RoomRenderer/room.js"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(fileURLWithPath: "/app/private.txt"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(string: "file:///app/RoomRenderer/index.html?command=logout"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(nil, index: index))
    }

    @MainActor
    func testObjectPicturesAskOnlyForHowAnObjectLooks() throws {
        let object = try RoomObject(.object([
            "id": .string("private-object-id"), "kind": .string("sink"), "roomId": .string("kitchen"),
            "slotId": .string("kitchen-sink"), "name": .string("Ada's private sink"), "variant": .string("original"),
            "finish": .string("sage"), "supplies": .array([.object([
                "id": .string("dish-soap"), "name": .string("Secret soap"), "quantity": .string("1 bottle"),
            ])]), "installed": .bool(true), "version": .integer(3), "state": .string("needs-cleaning"),
            "stateChangedAt": .string("2026-10-01T12:00:00Z"),
            "stateChangedBy": .string("22222222-2222-4222-8222-222222222222"),
        ]))
        let request = RoomThumbnails.request(object, roomStyle: "clay")
        XCTAssertEqual(Set(request.keys), ["version", "roomId", "kind", "slotId", "variant", "finish", "state", "roomStyle"])
        let body = String(describing: request)
        for secret in ["private-object-id", "Ada's private sink", "Secret soap", "22222222"] {
            XCTAssertFalse(body.contains(secret), secret)
        }
        XCTAssertNil(RoomThumbnails.decode("data:image/jpeg;base64,AAAA"))
        XCTAssertNil(RoomThumbnails.decode("https://example.test/sink.png"))
        XCTAssertNil(RoomThumbnails.decode(42))
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData())
        XCTAssertNotNil(RoomThumbnails.decode("data:image/png;base64," + png.base64EncodedString()))
    }
}
