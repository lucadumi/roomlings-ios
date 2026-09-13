import SwiftUI

struct RoomPreviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var generation = UUID()
    @State private var failure: String?
    @State private var accounts = AccountModel.live()
    @State private var showingAccount = false

    var body: some View {
        RoomWebView(paused: scenePhase != .active || showingAccount, room: accounts.room) { event in
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
        .safeAreaInset(edge: .top, spacing: 0) {
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
}
