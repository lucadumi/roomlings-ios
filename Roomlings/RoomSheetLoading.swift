import SwiftUI
import UIKit

struct RoomLoadingIcon: View {
    var size: CGFloat = 24

    private static let image = Bundle.main.url(forResource: "roomlings-loader", withExtension: "png", subdirectory: "RoomRenderer")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text("The Roomlings logo is missing. Rebuild the app with the shared web source.")
                .font(RoomTheme.body(14))
                .foregroundStyle(RoomTheme.error)
        }
    }
}

struct RoomSheetLoading: ViewModifier {
    let model: AccountModel
    let label: String
    var refreshOnOpen = true
    @State private var hasLoadedContent = false

    func body(content: Content) -> some View {
        ZStack {
            if hasLoadedContent && !model.refreshing {
                content
            } else {
                VStack(spacing: 16) {
                    RoomLoadingIcon(size: 64)
                    Text(label).font(RoomTheme.body()).foregroundStyle(RoomTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sheet-loading")
            }
        }
        .task {
            if refreshOnOpen { await model.refresh() }
            if !model.busy { hasLoadedContent = true }
        }
        .onChange(of: model.busy) { _, busy in
            if !busy { hasLoadedContent = true }
        }
    }
}
