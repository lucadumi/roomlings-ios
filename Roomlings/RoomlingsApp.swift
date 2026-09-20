import SwiftUI
import RoomlingsCore

@main
struct RoomlingsApp: App {
    @UIApplicationDelegateAdaptor(RoomlingsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            content
                .environment(appDelegate.notifications)
                .environment(\.roomControlAppearance, RoomControlAppearance.current)
                .preferredColorScheme(.light)
        }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-roomlings-control-fixture") {
            RoomControlAppearance.RoomControlStyleFixture()
        } else {
            RoomPreviewScreen()
        }
        #else
        RoomPreviewScreen()
        #endif
    }
}
