import SwiftUI
import WebKit

enum RoomRenderStatus: String, Decodable {
    case loading, ready, unavailable
}

enum RoomRenderEvent {
    case status(RoomRenderStatus)
    case failure(String)
}

struct RoomBridgeMessage: Decodable {
    let version: Int
    let type: String
    let status: RoomRenderStatus

    static func decode(_ body: Any) throws -> Self {
        guard let fields = body as? [String: Any],
              Set(fields.keys) == ["version", "type", "status"] else {
            throw BridgeError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        guard data.count <= 1_024 else { throw BridgeError.invalidMessage }
        let message = try JSONDecoder().decode(Self.self, from: data)
        guard message.version == 1, message.type == "status" else {
            throw BridgeError.invalidMessage
        }
        return message
    }

    enum BridgeError: Error {
        case invalidMessage
    }
}

struct RoomWebView: UIViewRepresentable {
    let paused: Bool
    var room = RoomVisualState.preview
    var viewportInsets = RoomViewportInsets.zero
    let onEvent: (RoomRenderEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(paused: paused, room: room, viewportInsets: viewportInsets, onEvent: onEvent)
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
        context.coordinator.update(paused: paused, room: room, viewportInsets: viewportInsets)
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
        private var loaded = false
        private var active = true

        init(paused: Bool, room: RoomVisualState = .preview, viewportInsets: RoomViewportInsets = .zero,
             onEvent: @escaping (RoomRenderEvent) -> Void) {
            self.paused = paused
            self.room = room
            self.viewportInsets = viewportInsets
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

        func update(paused: Bool, room: RoomVisualState, viewportInsets: RoomViewportInsets) {
            guard self.paused != paused || self.room != room || self.viewportInsets != viewportInsets else { return }
            self.paused = paused
            self.room = room
            self.viewportInsets = viewportInsets
            sendState()
        }

        private func sendState() {
            guard active, loaded, let webView else { return }
            evaluation?.cancel()
            let paused = paused
            let room = room
            let viewportInsets = viewportInsets
            evaluation = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "return window.RoomlingsRoom.receive(message);",
                        arguments: ["message": try room.message(paused: paused, viewportInsets: viewportInsets)],
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
                report(.status(try RoomBridgeMessage.decode(message.body).status))
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
