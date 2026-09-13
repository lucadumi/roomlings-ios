import XCTest
@testable import Roomlings

final class RoomBridgeTests: XCTestCase {
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
