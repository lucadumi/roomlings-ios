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
    @State private var roomID = RoomVisualState.defaultRoomID
    @State private var roomsOpen = false
    @State private var roomEntryFrame = CGRect.zero
    /// Chores opened from a notification start on that chore's room with My turn only.
    @State private var choreFocus: (roomID: String, mine: Bool)?
    /// Chores opened from a room object's Add chore start on the add form, with an optional routine.
    @State private var choreAdding: RoomObjectCatalog.Routine??
    @State private var thumbnails = RoomThumbnails()

    private enum Sheet: String, Identifiable {
        case account, chores, shopping, money, notifications, objects
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
                    RoomWebView(paused: scenePhase != .active || presentedSheet != nil, room: accounts.room.showing(room: roomID),
                                viewportInsets: insets, roomZoom: roomZoom, thumbnails: thumbnails) { event in
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
                RoomAccountHeader(accounts: accounts, roomID: roomID, roomsOpen: $roomsOpen,
                                  onRoomEntryFrame: { roomEntryFrame = $0 }, openNotifications: openNotifications,
                                  openObjects: openObjects) {
                    accounts.clearFeedback()
                    presentedSheet = .account
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                if roomsOpen, let rooms = accounts.choreCatalog?.rooms {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { roomsOpen = false }
                        .accessibilityHidden(true)
                    RoomPickerMenu(rooms: rooms, selection: roomID) { room in
                        roomID = room
                        roomsOpen = false
                    } onClose: {
                        roomsOpen = false
                    }
                    .padding(.leading, max(12, roomEntryFrame.minX))
                    .padding(.top, roomEntryFrame.maxY + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .coordinateSpace(.named(RoomAccountHeader.coordinateSpace))
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
            case .chores:
                ChoresSheet(model: accounts, object: choreObject, roomID: choreFocus?.roomID ?? roomID,
                            mine: choreFocus?.mine ?? false, adding: choreAdding)
            case .shopping: ShoppingSheet(model: accounts)
            case .money: MoneySheet(model: accounts, destination: moneyDestination)
            case .notifications: NotificationsSheet(model: accounts, onOpen: openInboxItem)
            case .objects: RoomObjectsSheet(model: accounts, roomID: roomID, thumbnails: thumbnails, onOpen: openObjectRoute)
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
            await accounts.loadInbox()
            await notifications.synchronize()
        }
        .onOpenURL(perform: receiveInvitation)
        .onChange(of: accounts.busy) { _, busy in
            if !busy {
                notifications.attach(to: accounts)
                presentPendingContent()
                Task {
                    // The bell's count needs this household's read state once the account settles.
                    if accounts.inboxRead == nil { await accounts.loadInbox() }
                    await notifications.synchronize()
                }
            }
        }
        .onChange(of: accounts.room.householdID) { _, householdID in
            failure = nil
            if householdID == nil { roomID = RoomVisualState.defaultRoomID }
            roomsOpen = false
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
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { accounts.analyticsBecameActive() }
            if phase == .background { accounts.analyticsEnteredBackground() }
            if phase == .active && accounts.restored && !accounts.busy {
                Task {
                    await accounts.refresh()
                    notifications.attach(to: accounts)
                    // Another device may have read notifications while this one was away.
                    await accounts.loadInbox()
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
                choreFocus = nil
                choreAdding = nil
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
            accounts.recordNotificationOpened(householdID: destination.householdID, at: pending.receivedAt)
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
            accounts.choreObjects.first { $0.id == id && $0.installed && $0.roomID == roomID }
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
            choreFocus = nil
            choreAdding = nil
            presentedSheet = .chores
        }
    }

    private func openNotifications() {
        guard accounts.canUseAccount, let householdID = accounts.state?.session?.household.id else {
            accounts.message = "Open your current household before reading its notifications."
            presentedSheet = .account
            return
        }
        if presentedSheet == nil {
            if !accounts.busy { accounts.clearFeedback() }
            sheetHouseholdID = householdID
            presentedSheet = .notifications
        }
    }

    private func openObjects() {
        guard accounts.canUseAccount, let householdID = accounts.state?.session?.household.id else {
            accounts.message = "Open your current household before viewing its room objects."
            presentedSheet = .account
            return
        }
        if presentedSheet == nil {
            if !accounts.busy { accounts.clearFeedback() }
            sheetHouseholdID = householdID
            presentedSheet = .objects
        }
    }

    /// Follows a room object's chores, supplies or shortcut to the native sheet that holds it.
    private func openObjectRoute(_ route: RoomObjectsSheet.Route) {
        choreObject = nil
        choreFocus = nil
        choreAdding = nil
        switch route {
        case .chores(let id):
            choreObject = accounts.choreObjects.first { $0.id == id }
            presentedSheet = .chores
        case .addChore(let id, let routine):
            choreObject = accounts.choreObjects.first { $0.id == id }
            choreAdding = .some(routine)
            presentedSheet = .chores
        case .roomChores:
            choreFocus = (roomID: roomID, mine: false)
            presentedSheet = .chores
        case .shopping:
            presentedSheet = .shopping
        case .receipts:
            moneyDestination = .receipts
            presentedSheet = .money
        case .balances:
            moneyDestination = nil
            presentedSheet = .money
        }
    }

    /// Opens what a notification is about, as the web inbox does, and marks it read.
    private func openInboxItem(_ item: InboxItem) {
        if accounts.inboxRead?.isUnread(item) == true {
            Task { await accounts.markInboxRead(InboxRead(through: nil, ids: [item.id])) }
        }
        accounts.clearFeedback()
        switch item.target {
        case .chore(let id):
            let chore = accounts.chores?.items.first { $0.id == id }
            choreObject = nil
            choreFocus = (roomID: chore?.roomID ?? "home", mine: true)
            choreAdding = nil
            presentedSheet = .chores
        case .receipt(let id):
            moneyDestination = .receipt(id)
            presentedSheet = .money
        case .bills(let month):
            moneyDestination = .bills(month: month)
            presentedSheet = .money
        case .repayment(let id):
            moneyDestination = .repayment(id)
            presentedSheet = .money
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
    static let coordinateSpace = "room-screen"
    let accounts: AccountModel
    let roomID: String
    @Binding var roomsOpen: Bool
    var onRoomEntryFrame: (CGRect) -> Void = { _ in }
    let openNotifications: () -> Void
    var openObjects: () -> Void = {}
    let openAccount: () -> Void

    var body: some View {
        // The room selector sits below the header, inside the measured area the room keeps clear.
        VStack(alignment: .leading, spacing: 8) {
            plate
            if accounts.room.householdID != nil {
                HStack(alignment: .top, spacing: 8) {
                    roomEntry
                    Spacer(minLength: 0)
                    objectsEntry
                    notificationsEntry
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var plate: some View {
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

    /// Rooms come from the shared catalog and need an open household, as on the web.
    @ViewBuilder private var roomEntry: some View {
        if accounts.room.householdID != nil, let rooms = accounts.choreCatalog?.rooms, rooms.count > 1 {
            let current = rooms.first { $0.id == roomID } ?? rooms[0]
            Button { roomsOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .accessibilityHidden(true)
                    Text(current.name)
                        .font(RoomTheme.body(14).weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(RoomTheme.ink)
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(accounts.busy)
            .accessibilityLabel("Rooms")
            .accessibilityValue(current.name)
            .accessibilityHint("Chooses which shared room to show")
            .accessibilityAddTraits(roomsOpen ? .isSelected : [])
            .accessibilityIdentifier("room-entry")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { onRoomEntryFrame($0) }
        }
    }

    /// The current room's objects, beside the bell as the web keeps it with the room tools.
    @ViewBuilder private var objectsEntry: some View {
        if accounts.canUseAccount {
            Button(action: openObjects) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RoomTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(accounts.busy)
            .accessibilityLabel("Room objects")
            .accessibilityIdentifier("room-objects-entry")
        }
    }

    /// The household inbox, beside Rooms as the web keeps it with the room tools.
    @ViewBuilder private var notificationsEntry: some View {
        if accounts.canUseAccount {
            let unread = accounts.inboxUnreadCount
            Button(action: openNotifications) {
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RoomTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Text(unread > 9 ? "9+" : "\(unread)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(RoomTheme.paper)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(RoomTheme.tomato, in: Capsule())
                                .overlay(Capsule().stroke(RoomTheme.paper))
                                .offset(x: 5, y: -5)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(accounts.busy)
            .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
            .accessibilityIdentifier("notifications-entry")
        }
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

/// The compact web room picker (`src/roomPicker.css`): a bordered control surface with one row
/// per room, the current room checked on a sage background and the others marked with an arrow.
struct RoomPickerMenu: View {
    let rooms: [ChoreCatalog.Room]
    let selection: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rooms) { room in
                let selected = room.id == selection
                Button { onSelect(room.id) } label: {
                    HStack(spacing: 8) {
                        Text(room.name)
                            .font(RoomTheme.heading(14))
                            .foregroundStyle(RoomTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selected ? "checkmark" : "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RoomTheme.ink)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .background(selected ? RoomTheme.leafSoft : RoomTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? RoomTheme.border : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(room.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: 224)
        // Only the panel casts the shadow, not each option drawn on it.
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(RoomTheme.surface)
                .shadow(color: RoomTheme.ink.opacity(0.16), radius: 14, y: 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rooms")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("room-picker")
    }
}
