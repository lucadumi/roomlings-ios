import RoomlingsCore
import SwiftUI

struct RoomPreviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NativeNotifications.self) private var notifications
    @State private var generation = UUID()
    @State private var failure: String?
    @State private var accounts = AccountModel.live()
    @State private var presentedSheet: Sheet?
    @State private var choreObject: ChoreObject?
    @State private var headerHeight: CGFloat = 88
    @State private var invitationPresentationPending = false
    @State private var roomZoom: Double?
    @State private var viewportFailure: String?
    @State private var openingNotification = false
    @State private var sheetHouseholdID: UUID?
    @State private var moneyDestination: MoneySheet.Destination?

    private enum Sheet: String, Identifiable {
        case account, chores, shopping, money
        var id: String { rawValue }
    }

    private struct Viewport: Equatable {
        let size: CGSize
        let safeAreaInsets: EdgeInsets
    }

    enum ViewportError: Error {
        case invalidSize
    }

    static func roomZoom(for size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets()) throws -> Double {
        let measurements = [size.width, size.height, safeAreaInsets.top, safeAreaInsets.leading,
                            safeAreaInsets.bottom, safeAreaInsets.trailing]
        guard measurements.allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              measurements.dropFirst(2).allSatisfy({ $0 >= 0 }) else { throw ViewportError.invalidSize }
        // The WKWebView extends beyond the GeometryReader's safe-area content on every edge.
        let width = size.width + safeAreaInsets.leading + safeAreaInsets.trailing
        let height = size.height + safeAreaInsets.top + safeAreaInsets.bottom
        guard width.isFinite, height.isFinite else { throw ViewportError.invalidSize }
        let entryAspect = 0.767
        return min(1, max(0.3, Double(width / height) / entryAspect))
    }

    var body: some View {
        GeometryReader { geometry in
            let viewport = Viewport(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
            let insets = RoomViewportInsets(
                top: Double(max(0, geometry.safeAreaInsets.top + headerHeight)),
                right: Double(max(0, geometry.safeAreaInsets.trailing)),
                bottom: Double(max(0, geometry.safeAreaInsets.bottom)),
                left: Double(max(0, geometry.safeAreaInsets.leading))
            )
            ZStack(alignment: .top) {
                RoomTheme.paper.ignoresSafeArea(.container)
                if let roomZoom {
                    RoomWebView(paused: scenePhase != .active || presentedSheet != nil, room: accounts.room,
                                viewportInsets: insets, roomZoom: roomZoom) { event in
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
                }
                roomFailure
                RoomAccountHeader(accounts: accounts) {
                    accounts.clearFeedback()
                    presentedSheet = .account
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .onChange(of: viewport, initial: true) { _, viewport in
                do {
                    roomZoom = try Self.roomZoom(for: viewport.size, safeAreaInsets: viewport.safeAreaInsets)
                    viewportFailure = nil
                } catch {
                    viewportFailure = "The room size could not be measured. Resize the window or rotate the device to try again."
                }
            }
        }
        .sheet(item: $presentedSheet, onDismiss: presentPendingContent) { sheet in
            switch sheet {
            case .account: AccountSheet(model: accounts)
            case .chores: ChoresSheet(model: accounts, object: choreObject)
            case .shopping: ShoppingSheet(model: accounts)
            case .money: MoneySheet(model: accounts, destination: moneyDestination)
            }
        }
        .task {
            await accounts.start()
            notifications.attach(to: accounts)
            #if DEBUG
            if let input = ProcessInfo.processInfo.environment["ROOMLINGS_INVITATION_URL"],
               let url = URL(string: input) {
                receiveInvitation(url)
            }
            if let payload = ProcessInfo.processInfo.environment["ROOMLINGS_NOTIFICATION_PAYLOAD"] {
                notifications.receiveNotification(Data(payload.utf8))
            }
            #endif
            if !accounts.signedIn || accounts.state?.session == nil || accounts.message != nil {
                presentedSheet = .account
            }
            presentPendingContent()
            await notifications.synchronize()
        }
        .onOpenURL(perform: receiveInvitation)
        .onChange(of: accounts.busy) { _, busy in
            if !busy {
                notifications.attach(to: accounts)
                presentPendingContent()
                Task { await notifications.synchronize() }
            }
        }
        .onChange(of: accounts.room.householdID) { _, householdID in
            failure = nil
            notifications.attach(to: accounts)
            if sheetHouseholdID != accounts.state?.session?.household.id {
                choreObject = nil
                moneyDestination = nil
                if presentedSheet == .chores || presentedSheet == .shopping || presentedSheet == .money {
                    presentedSheet = householdID == nil ? .account : nil
                }
            }
        }
        .onChange(of: accounts.signedIn) { previous, signedIn in
            notifications.attach(to: accounts)
            if previous && !signedIn { presentedSheet = .account }
        }
        .onChange(of: notifications.pending) { _, pending in
            if pending != nil, presentedSheet != nil {
                accounts.notice = "A notification is waiting. Finish here, then close this sheet to open it."
            }
            presentPendingContent()
        }
        .onChange(of: notifications.routingError) { _, error in
            if let error {
                accounts.message = error
                if presentedSheet == nil { presentedSheet = .account }
            }
        }
        .onChange(of: openingNotification) { _, opening in
            if !opening { presentPendingContent() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && accounts.restored && !accounts.busy {
                Task {
                    await accounts.refresh()
                    notifications.attach(to: accounts)
                    await notifications.synchronize()
                }
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

    private func presentPendingContent() {
        presentPendingInvitation()
        guard !openingNotification, !accounts.busy, presentedSheet == nil,
              let pending = notifications.pending else { return }
        guard accounts.canUseAccount else {
            presentedSheet = .account
            return
        }
        openingNotification = true
        Task {
            defer { openingNotification = false }
            guard await accounts.refresh() else {
                presentedSheet = .account
                return
            }
            guard notifications.pending?.id == pending.id else { return }
            let destination = pending.destination
            guard accounts.state?.memberships.contains(where: { $0.householdID == destination.householdID }) == true else {
                rejectPendingNotification(pending.id, "That notification no longer belongs to a household you can access.")
                return
            }
            if accounts.state?.session?.household.id != destination.householdID {
                guard await accounts.select(id: destination.householdID) else {
                    presentedSheet = .account
                    return
                }
            }
            guard notifications.pending?.id == pending.id,
                  accounts.state?.session?.household.id == destination.householdID else { return }
            sheetHouseholdID = destination.householdID
            switch destination.target {
            case .chores(let componentID):
                guard accounts.chores != nil else {
                    rejectPendingNotification(pending.id, accounts.choresFailure ?? "Your chores could not be loaded.")
                    return
                }
                let object = componentID.flatMap { id in accounts.choreObjects.first { $0.id == id && $0.installed } }
                guard componentID == nil || object != nil else {
                    rejectPendingNotification(pending.id, "That chore object is no longer available. Open Chores to review the current list.")
                    return
                }
                choreObject = object
                presentedSheet = .chores
            case .expense(let id):
                guard accounts.ledger?.expenses.contains(where: { $0.id == id }) == true else {
                    rejectPendingNotification(pending.id, "That receipt is no longer available. Open Money to review the current ledger.")
                    return
                }
                moneyDestination = .receipt(id)
                presentedSheet = .money
            case .settlement(let id):
                guard accounts.ledger?.settlements.contains(where: { $0.id == id }) == true else {
                    rejectPendingNotification(pending.id, "That repayment is no longer available. Open Money to review the current ledger.")
                    return
                }
                moneyDestination = .repayment(id)
                presentedSheet = .money
            }
            notifications.finishOpening(pending.id)
        }
    }

    private func rejectPendingNotification(_ id: UUID, _ message: String) {
        notifications.finishOpening(id)
        accounts.message = message
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
            sheetHouseholdID = householdID
            moneyDestination = nil
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
            sheetHouseholdID = householdID
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
            sheetHouseholdID = householdID
            choreObject = object
            presentedSheet = .chores
        }
    }

    @ViewBuilder private var roomFailure: some View {
        if let failure = failure ?? viewportFailure ?? accounts.roomFailure {
            ContentUnavailableView {
                Label("Room unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                if viewportFailure == nil {
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
            }
            .background(.background)
        }
    }
}

struct RoomAccountHeader: View {
    let accounts: AccountModel
    let openAccount: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                brand
                householdEntry(singleLine: true)
                Spacer(minLength: 0)
                accountEntry
            }
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    brand
                    householdEntry(singleLine: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer(minLength: 0)
                    accountEntry
                }
            }
        }
        .foregroundStyle(RoomTheme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-account-header")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoomBrandMark(size: 36)
            Rectangle()
                .fill(RoomTheme.line)
                .frame(width: 1, height: 24)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }

    private func householdEntry(singleLine: Bool) -> some View {
        Button(action: openAccount) {
            HStack(spacing: 8) {
                Text(accounts.householdName ?? "Kitchen preview")
                    .font(RoomTheme.body(14).weight(.semibold))
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: singleLine, vertical: true)
                    .multilineTextAlignment(.leading)
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .padding(3)
                    .background(statusColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accounts.householdName ?? "Kitchen preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("household-entry")
        .accessibilityValue(accounts.headerStatus.label)
        .accessibilityHint("Opens your account")
    }

    private var statusColor: Color {
        switch accounts.headerStatus {
        case .loaded: RoomTheme.leaf
        case .needsAttention: RoomTheme.error
        case .preview, .updating: RoomTheme.muted
        }
    }

    private var accountEntry: some View {
        Button(action: openAccount) {
            if let viewer = accounts.viewer, let color = accounts.viewerColor {
                Text(viewer.name.prefix(1).uppercased())
                    .font(RoomTheme.body(15).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 35, height: 35)
                    .frame(width: 41, height: 41)
                    .background(RoomTheme.member(color), in: Circle())
                    .overlay(Circle().strokeBorder(RoomTheme.paper, lineWidth: 3))
                    .overlay(Circle().stroke(RoomTheme.border))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                Text(accounts.signedIn ? "Account" : "Sign in")
                    .font(RoomTheme.body(14).weight(.semibold))
                    .foregroundStyle(RoomTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(RoomTheme.surfaceMuted, in: Capsule())
                    .overlay(Capsule().stroke(RoomTheme.border))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("account-entry")
        .accessibilityLabel(accounts.signedIn ? "Account" : "Sign in")
        .accessibilityValue(accounts.viewer.map { "Playing as \($0.name)" } ?? "")
    }
}
