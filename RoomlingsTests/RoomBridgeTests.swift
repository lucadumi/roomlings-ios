import XCTest
import RoomlingsCore
import UIKit
@testable import Roomlings

final class RoomBridgeTests: XCTestCase {
    func testTheWebFontFamiliesAreRegisteredNatively() {
        XCTAssertNotNil(UIFont(name: "DMSans-9ptRegular_Regular", size: 16))
        XCTAssertNotNil(UIFont(name: "Baloo2-SemiBold", size: 26))
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
        let message = try visual.message(paused: true, viewportInsets: insets)
        XCTAssertEqual(Set(message.keys), ["version", "type", "paused", "householdId", "roomStyle", "roomComponents", "viewportInsets"])
        XCTAssertEqual((message["viewportInsets"] as? [String: Double])?["top"], 150)
        XCTAssertEqual(message["householdId"] as? String, householdID)
        XCTAssertEqual(message["roomStyle"] as? String, "clay")
        XCTAssertEqual(message["paused"] as? Bool, true)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        for privateValue in ["private-invitation", "Ada", memberID, "budget", "expenses", "accessToken", "csrfToken"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        let preview = try RoomVisualState.preview.message(paused: false)
        XCTAssertNil(preview["householdId"])
        XCTAssertNil(preview["roomComponents"])
    }

    func testOnlyKnownStatusMessagesAreAccepted() throws {
        let message = try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "ready"])
        XCTAssertEqual(message.status, .ready)
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 2, "type": "status", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": true, "type": "status", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "request", "status": "ready"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "unknown"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status", "status": "ready", "url": "https://example.com"]))
        XCTAssertThrowsError(try RoomBridgeMessage.decode(["version": 1, "type": "status"]))
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
