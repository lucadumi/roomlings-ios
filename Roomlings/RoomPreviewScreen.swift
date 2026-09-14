import SwiftUI

struct RoomPreviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var generation = UUID()
    @State private var failure: String?
    @State private var accounts = AccountModel.live()
    @State private var showingAccount = false
    @State private var headerHeight: CGFloat = 88

    var body: some View {
        GeometryReader { geometry in
            let insets = RoomViewportInsets(
                top: Double(max(0, geometry.safeAreaInsets.top + headerHeight)),
                right: Double(max(0, geometry.safeAreaInsets.trailing)),
                bottom: Double(max(0, geometry.safeAreaInsets.bottom)),
                left: Double(max(0, geometry.safeAreaInsets.leading))
            )
            ZStack(alignment: .top) {
                RoomWebView(paused: scenePhase != .active || showingAccount, room: accounts.room, viewportInsets: insets) { event in
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
                .ignoresSafeArea(.container)
                roomFailure
                accountHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
        }
        .sheet(isPresented: $showingAccount) { AccountSheet(model: accounts) }
        .task {
            await accounts.start()
            showingAccount = !accounts.signedIn || accounts.state?.session == nil || accounts.message != nil
        }
        .onChange(of: accounts.room.householdID) { failure = nil }
        .onChange(of: accounts.signedIn) { previous, signedIn in
            if previous && !signedIn { showingAccount = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && accounts.restored && !accounts.busy {
                Task { await accounts.refresh() }
            }
        }
    }

    private var accountHeader: some View {
        HStack {
            Text(accounts.householdName ?? "Kitchen preview")
                .font(RoomTheme.body(14).weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("household-title")
            Spacer(minLength: 12)
            Button {
                showingAccount = true
            } label: {
                Label(accounts.signedIn ? "Account" : "Sign in", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("account-entry")
            .buttonStyle(RoomButtonStyle(kind: .text))
        }
        .foregroundStyle(RoomTheme.ink)
        .padding(12)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var roomFailure: some View {
        if let failure = failure ?? accounts.roomFailure {
            ContentUnavailableView {
                Label("Room unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button(accounts.roomFailure == nil ? "Reload room" : "Refresh account") {
                    if accounts.roomFailure != nil {
                        Task { await accounts.refresh() }
                    } else {
                        self.failure = nil
                        generation = UUID()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .background(.background)
        }
    }
}
