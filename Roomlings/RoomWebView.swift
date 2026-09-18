import SwiftUI
import WebKit

enum RoomRenderStatus: String, Decodable {
    case loading, ready, unavailable
}

enum RoomRenderEvent: Equatable {
    case status(RoomRenderStatus)
    case openChores(householdID: UUID, componentID: String? = nil)
    case openShopping(householdID: UUID)
    case failure(String)
}

struct RoomBridgeMessage: Decodable {
    let event: RoomRenderEvent

    private enum CodingKeys: String, CodingKey {
        case version, type, status
        case householdID = "householdId"
        case componentID = "componentId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw BridgeError.invalidMessage
        }
        switch try container.decode(String.self, forKey: .type) {
        case "status":
            event = .status(try container.decode(RoomRenderStatus.self, forKey: .status))
        case "open-chores":
            let componentID: String?
            if container.contains(.componentID) {
                let value = try container.decode(String.self, forKey: .componentID)
                guard (1...100).contains(value.utf16.count) else { throw BridgeError.invalidMessage }
                componentID = value
            } else {
                componentID = nil
            }
            event = .openChores(householdID: try container.decode(UUID.self, forKey: .householdID), componentID: componentID)
        case "open-shopping":
            event = .openShopping(householdID: try container.decode(UUID.self, forKey: .householdID))
        default:
            throw BridgeError.invalidMessage
        }
    }

    static func decode(_ body: Any) throws -> Self {
        guard let fields = body as? [String: Any] else {
            throw BridgeError.invalidMessage
        }
        var expected: Set<String>
        switch fields["type"] as? String {
        case "status": expected = ["version", "type", "status"]
        case "open-chores":
            expected = ["version", "type", "householdId"]
            if fields.keys.contains("componentId") { expected.insert("componentId") }
        case "open-shopping":
            expected = ["version", "type", "householdId"]
        default: throw BridgeError.invalidMessage
        }
        guard Set(fields.keys) == expected else {
            throw BridgeError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        guard data.count <= 1_024 else { throw BridgeError.invalidMessage }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    enum BridgeError: Error {
        case invalidMessage
    }
}

struct RoomWebView: UIViewRepresentable {
    let paused: Bool
    var room = RoomVisualState.preview
    var viewportInsets = RoomViewportInsets.zero
    var roomZoom: Double = 1
    let onEvent: (RoomRenderEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(paused: paused, room: room, viewportInsets: viewportInsets, roomZoom: roomZoom, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.ignoresViewportScaleLimits = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "roomlings")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.accessibilityIdentifier = "room-renderer"
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .white
        context.coordinator.webView = webView

        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "RoomRenderer") {
            context.coordinator.index = index
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            Task { @MainActor in
                onEvent(.failure("The shared room bundle is missing. Build the app with the configured web source checkout."))
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.update(paused: paused, room: room, viewportInsets: viewportInsets, roomZoom: roomZoom)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "roomlings")
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var index: URL?
        var onEvent: (RoomRenderEvent) -> Void
        var evaluation: Task<Void, Never>?
        private var paused: Bool
        private var room: RoomVisualState
        private var viewportInsets: RoomViewportInsets
        private var roomZoom: Double
        private var loaded = false
        private var active = true

        init(paused: Bool, room: RoomVisualState = .preview, viewportInsets: RoomViewportInsets = .zero,
             roomZoom: Double = 1, onEvent: @escaping (RoomRenderEvent) -> Void) {
            self.paused = paused
            self.room = room
            self.viewportInsets = viewportInsets
            self.roomZoom = roomZoom
            self.onEvent = onEvent
        }

        func invalidate() {
            active = false
            loaded = false
            evaluation?.cancel()
        }

        private func report(_ event: RoomRenderEvent) {
            if active { onEvent(event) }
        }

        static func allows(_ url: URL?, index: URL?) -> Bool {
            guard let url, let index, url.isFileURL, url.query == nil, url.fragment == nil else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath() == index.standardizedFileURL.resolvingSymlinksInPath()
        }

        func update(paused: Bool, room: RoomVisualState, viewportInsets: RoomViewportInsets, roomZoom: Double) {
            guard self.paused != paused || self.room != room || self.viewportInsets != viewportInsets
                    || self.roomZoom != roomZoom else { return }
            self.paused = paused
            self.room = room
            self.viewportInsets = viewportInsets
            self.roomZoom = roomZoom
            sendState()
        }

        private func sendState() {
            guard active, loaded, let webView else { return }
            evaluation?.cancel()
            let paused = paused
            let room = room
            let viewportInsets = viewportInsets
            let roomZoom = roomZoom
            evaluation = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "return window.RoomlingsRoom.receive(message);",
                        arguments: ["message": try room.message(paused: paused, viewportInsets: viewportInsets, roomZoom: roomZoom)],
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    if !Task.isCancelled {
                        self.report(.failure("The native app could not update the room. Reload the room to try again."))
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active else { return }
            guard message.name == "roomlings", message.frameInfo.isMainFrame,
                  message.webView === webView, Self.allows(message.frameInfo.request.url, index: index) else {
                report(.failure("The app blocked a message from outside the bundled room."))
                return
            }
            do {
                report(try RoomBridgeMessage.decode(message.body).event)
            } catch {
                report(.failure("The room sent an invalid app message. Reload the room to try again."))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(active && navigationAction.targetFrame?.isMainFrame == true
                && Self.allows(navigationAction.request.url, index: index) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }
            loaded = true
            sendState()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(.failure("The bundled room could not be loaded. Reload the room to try again."))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(.failure("The bundled room could not be opened. Reload the room to try again."))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            report(.failure("The room renderer stopped. Reload the room to continue."))
        }
    }
}
