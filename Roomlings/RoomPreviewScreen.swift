import SwiftUI

struct RoomPreviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var generation = UUID()
    @State private var failure: String?

    var body: some View {
        RoomWebView(paused: scenePhase != .active) { event in
            switch event {
            case .status(.unavailable):
                failure = "The shared room renderer could not start. Reload the room to try again."
            case .failure(let message):
                failure = message
            case .status:
                break
            }
        }
        .id(generation)
        .overlay {
            if let failure {
                ContentUnavailableView {
                    Label("Room unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Reload room") {
                        self.failure = nil
                        generation = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .background(.background)
            }
        }
    }
}
