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
            "expenses": [], "settlements": [], "roomComponents": [],
        ])
        let household = try JSONDecoder().decode(HouseholdSnapshot.self, from: data)
        let visual = try RoomVisualState(household: household)
        let insets = RoomViewportInsets(top: 150, right: 12, bottom: 34, left: 12)
        let message = try visual.message(paused: true, viewportInsets: insets, roomZoom: 1.35)
        XCTAssertEqual(Set(message.keys), ["version", "type", "paused", "householdId", "choresEnabled", "shoppingEnabled", "moneyEnabled", "roomStyle", "roomZoom", "roomComponents", "viewportInsets"])
        XCTAssertEqual((message["viewportInsets"] as? [String: Double])?["top"], 150)
        XCTAssertEqual(message["householdId"] as? String, householdID)
        XCTAssertEqual(message["roomStyle"] as? String, "clay")
        XCTAssertEqual(message["paused"] as? Bool, true)
        XCTAssertEqual(message["choresEnabled"] as? Bool, true)
        XCTAssertEqual(message["shoppingEnabled"] as? Bool, true)
        XCTAssertEqual(message["moneyEnabled"] as? Bool, true)
        XCTAssertEqual(message["roomZoom"] as? Double, 1.35)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        for privateValue in ["private-invitation", "Ada", memberID, "budget", "expenses", "accessToken", "csrfToken"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        let preview = try RoomVisualState.preview.message(paused: false)
        XCTAssertNil(preview["householdId"])
        XCTAssertNil(preview["roomComponents"])
        XCTAssertEqual(preview["choresEnabled"] as? Bool, false)
        XCTAssertEqual(preview["shoppingEnabled"] as? Bool, false)
        XCTAssertEqual(preview["moneyEnabled"] as? Bool, false)
        XCTAssertEqual(preview["roomZoom"] as? Double, 1)
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
    func testNavigationIsRestrictedToTheBundledEntry() {
        let index = URL(fileURLWithPath: "/app/RoomRenderer/index.html")
        XCTAssertTrue(RoomWebView.Coordinator.allows(index, index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(string: "https://example.com"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(fileURLWithPath: "/app/RoomRenderer/room.js"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(fileURLWithPath: "/app/private.txt"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(URL(string: "file:///app/RoomRenderer/index.html?command=logout"), index: index))
        XCTAssertFalse(RoomWebView.Coordinator.allows(nil, index: index))
    }
}
