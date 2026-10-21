import RoomlingsCore
import SwiftUI
import WebKit

enum RoomRenderStatus: String, Decodable {
    case loading, ready, unavailable
}

enum RoomRenderEvent: Equatable {
    case status(RoomRenderStatus)
    case openChores(householdID: UUID, componentID: String? = nil)
    case openShopping(householdID: UUID)
    case openMoney(householdID: UUID)
    case failure(String)
}

/// iOS ends WebKit's content process under memory pressure, often while the app is in the
/// background. The bundled room reloads once on its own; a renderer that keeps stopping
/// still shows the manual reload instead of looping.
struct RoomRecovery {
    static let interval: TimeInterval = 60
    private var lastReload: Date?

    mutating func shouldReload(at now: Date) -> Bool {
        if let lastReload, now.timeIntervalSince(lastReload) < Self.interval { return false }
        lastReload = now
        return true
    }
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
        case "open-money":
            event = .openMoney(householdID: try container.decode(UUID.self, forKey: .householdID))
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
        case "open-money":
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

/// Object pictures drawn by the bundled room with the web's own thumbnail renderer
/// (`src/componentThumbnail.ts`). Requests carry only how an object looks, never household data.
@MainActor @Observable
final class RoomThumbnails {
    enum Picture: Equatable {
        case loading, image(UIImage), unavailable
    }

    @ObservationIgnored weak var webView: WKWebView?
    private(set) var pictures: [String: Picture] = [:]

    /// How an object looks: all a picture needs. Drafts in the room editor are drawn before they are saved.
    struct Look: Hashable {
        let kind: String
        let roomID: String
        let slotID: String
        let variant: String
        let finish: String
        let state: String?

        init(_ object: RoomObject) {
            self.init(RoomObjectConfiguration(object), state: object.state)
        }

        init(_ object: RoomObjectConfiguration, state: String? = nil) {
            kind = object.kind
            roomID = object.roomID
            slotID = object.slotID
            variant = object.variant
            finish = object.finish
            self.state = state
        }
    }

    static func request(_ object: RoomObject, roomStyle: String) -> [String: Any] {
        request(Look(object), roomStyle: roomStyle)
    }

    static func request(_ look: Look, roomStyle: String) -> [String: Any] {
        [
            "version": 1, "roomId": look.roomID, "kind": look.kind, "slotId": look.slotID,
            "variant": look.variant, "finish": look.finish, "state": look.state ?? NSNull(), "roomStyle": roomStyle,
        ]
    }

    static func key(_ look: Look, roomStyle: String) -> String {
        [look.kind, look.slotID, look.variant, look.finish, look.state ?? "", roomStyle].joined(separator: ":")
    }

    func picture(_ object: RoomObject, roomStyle: String) -> Picture {
        picture(Look(object), roomStyle: roomStyle)
    }

    func picture(_ look: Look, roomStyle: String) -> Picture {
        pictures[Self.key(look, roomStyle: roomStyle)] ?? .loading
    }

    func load(_ object: RoomObject, roomStyle: String) {
        load(Look(object), roomStyle: roomStyle)
    }

    /// Draws a picture once per look. A failed picture is drawn again the next time the sheet asks.
    func load(_ look: Look, roomStyle: String) {
        let key = Self.key(look, roomStyle: roomStyle)
        if let current = pictures[key], current != .unavailable { return }
        guard let webView else {
            pictures[key] = .unavailable
            return
        }
        pictures[key] = .loading
        let request = Self.request(look, roomStyle: roomStyle)
        Task { [weak self, weak webView] in
            guard let webView else { return }
            let picture: Picture
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.RoomlingsRoom.thumbnail(request);",
                    arguments: ["request": request], in: nil, contentWorld: .page
                )
                picture = Self.decode(result).map(Picture.image) ?? .unavailable
            } catch {
                picture = .unavailable
            }
            self?.pictures[key] = picture
        }
    }

    static func decode(_ result: Any?) -> UIImage? {
        let prefix = "data:image/png;base64,"
        guard let url = result as? String, url.hasPrefix(prefix), url.utf8.count <= 4_000_000,
              let data = Data(base64Encoded: String(url.dropFirst(prefix.count))) else { return nil }
        return UIImage(data: data)
    }
}

struct RoomWebView: UIViewRepresentable {
    let paused: Bool
    var room = RoomVisualState.preview
    var viewportInsets = RoomViewportInsets.zero
    var roomZoom: Double = 1
    var thumbnails: RoomThumbnails?
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
        context.coordinator.thumbnails = thumbnails
        thumbnails?.webView = webView

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
        coordinator.thumbnails?.webView = nil
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var thumbnails: RoomThumbnails?
        var index: URL?
        var onEvent: (RoomRenderEvent) -> Void
        var evaluation: Task<Void, Never>?
        private var paused: Bool
        private var room: RoomVisualState
        private var viewportInsets: RoomViewportInsets
        private var roomZoom: Double
        private var loaded = false
        private var active = true
        private var recovery = RoomRecovery()
        var now: () -> Date = Date.init

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
            evaluation?.cancel()
            guard active else { return }
            if webView === self.webView, let index, recovery.shouldReload(at: now()) {
                webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
                return
            }
            report(.failure("The room renderer stopped. Reload the room to continue."))
        }
    }
}
