import SwiftUI
import RoomlingsCore

@main
struct RoomlingsApp: App {
    var body: some Scene {
        WindowGroup {
            RoomPreviewScreen()
                .preferredColorScheme(.light)
        }
    }
}
