import SwiftUI

struct RoomPreviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var generation = UUID()
    @State private var failure: String?
    @State private var accounts = AccountModel.live()
    @State private var presentedSheet: Sheet?
    @State private var choreObject: ChoreObject?
    @State private var headerHeight: CGFloat = 88
    @State private var invitationPresentationPending = false

    private enum Sheet: String, Identifiable {
        case account, chores, shopping, money
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let insets = RoomViewportInsets(
                top: Double(max(0, geometry.safeAreaInsets.top + headerHeight)),
                right: Double(max(0, geometry.safeAreaInsets.trailing)),
                bottom: Double(max(0, geometry.safeAreaInsets.bottom)),
                left: Double(max(0, geometry.safeAreaInsets.leading))
            )
            ZStack(alignment: .top) {
                RoomWebView(paused: scenePhase != .active || presentedSheet != nil, room: accounts.room, viewportInsets: insets,
                            roomZoom: UIDevice.current.userInterfaceIdiom == .phone && geometry.size.height > geometry.size.width ? 1.35 : 1) { event in
                    switch event {
                    case .status(.unavailable):
                        failure = "The shared room renderer could not start. Reload the room to try again."
                    case .failure(let message):
                        failure = message
                    case .status:
                        break
                    case .openChores(let householdID, let componentID):
                        openChores(householdID: householdID, componentID: componentID)
                    case .openShopping(let householdID):
                        openShopping(householdID: householdID)
                    case .openMoney(let householdID):
                        openMoney(householdID: householdID)
                    }
                }
                .id(generation)
                .ignoresSafeArea(.container)
                roomFailure
                accountHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
        }
        .sheet(item: $presentedSheet, onDismiss: presentPendingInvitation) { sheet in
            switch sheet {
            case .account: AccountSheet(model: accounts)
            case .chores: ChoresSheet(model: accounts, object: choreObject)
            case .shopping: ShoppingSheet(model: accounts)
            case .money: MoneySheet(model: accounts)
            }
        }
        .task {
            await accounts.start()
            #if DEBUG
            if let input = ProcessInfo.processInfo.environment["ROOMLINGS_INVITATION_URL"],
               let url = URL(string: input) {
                receiveInvitation(url)
            }
            #endif
            if !accounts.signedIn || accounts.state?.session == nil || accounts.message != nil {
                presentedSheet = .account
            }
            presentPendingInvitation()
        }
        .onOpenURL(perform: receiveInvitation)
        .onChange(of: accounts.busy) { _, busy in
            if !busy { presentPendingInvitation() }
        }
        .onChange(of: accounts.room.householdID) { _, householdID in
            failure = nil
            choreObject = nil
            if presentedSheet == .chores || presentedSheet == .shopping || presentedSheet == .money {
                presentedSheet = householdID == nil ? .account : nil
            }
        }
        .onChange(of: accounts.signedIn) { previous, signedIn in
            if previous && !signedIn { presentedSheet = .account }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && accounts.restored && !accounts.busy {
                Task { await accounts.refresh() }
            }
        }
    }

    private func receiveInvitation(_ url: URL) {
        accounts.receiveInvitation(url)
        invitationPresentationPending = true
        if presentedSheet != nil && presentedSheet != .account && !accounts.busy {
            accounts.notice = "An invitation is waiting in Account. Finish here, then close this sheet to review it."
        }
        presentPendingInvitation()
    }

    private func presentPendingInvitation() {
        guard invitationPresentationPending, !accounts.busy,
              presentedSheet == nil || presentedSheet == .account else { return }
        invitationPresentationPending = false
        presentedSheet = .account
    }

    private func openMoney(householdID: UUID) {
        guard accounts.canUseAccount, accounts.state?.session?.household.id == householdID else {
            accounts.message = "Open your current household before using its money."
            presentedSheet = .account
            return
        }
        if presentedSheet == nil {
            if !accounts.busy { accounts.clearFeedback() }
            presentedSheet = .money
        }
    }

    private func openShopping(householdID: UUID) {
        guard accounts.canUseAccount, accounts.state?.session?.household.id == householdID else {
            accounts.message = "Open your current household before using its shopping list."
            presentedSheet = .account
            return
        }
        if presentedSheet == nil {
            if !accounts.busy { accounts.clearFeedback() }
            presentedSheet = .shopping
        }
    }

    private func openChores(householdID: UUID, componentID: String?) {
        guard accounts.canUseAccount, accounts.state?.session?.household.id == householdID else {
            accounts.message = "Open your current household before using its chores."
            presentedSheet = .account
            return
        }
        let object = componentID.flatMap { id in
            accounts.choreObjects.first { $0.id == id && $0.installed && $0.roomID == "kitchen" }
        }
        guard componentID == nil || object != nil else {
            accounts.message = "That object is no longer available in this room. Refresh your account."
            presentedSheet = .account
            return
        }
        if presentedSheet == nil {
            if !accounts.busy { accounts.clearFeedback() }
            choreObject = object
            presentedSheet = .chores
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
                accounts.clearFeedback()
                presentedSheet = .account
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
