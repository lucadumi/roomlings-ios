import RoomlingsCore
import SwiftUI

/// The household inbox, matching the web Notifications panel (`src/Inbox.tsx`). Items are derived
/// from the saved household; only your read state is stored, privately, on the server.
struct NotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountModel
    let onOpen: (InboxItem) -> Void
    @State private var contentHeight: CGFloat = 320
    @State private var headerHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Notifications").font(RoomTheme.heading()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Done") { dismiss() }
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = model.message {
                        RoomFeedback(message, identifier: "inbox-error")
                    }
                    content
                }
                .padding(24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .tint(RoomTheme.sage)
        .task { await model.loadInbox() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
    }

    @ViewBuilder private var content: some View {
        let items = model.inboxItems
        if let read = model.inboxRead {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell")
                        .font(.system(size: 30))
                        .foregroundStyle(RoomTheme.leaf)
                        .accessibilityHidden(true)
                    Text("All caught up.").font(RoomTheme.heading(23)).foregroundStyle(RoomTheme.muted)
                    Text("Your chore turns and the money that involves you will show up here.")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox-empty")
            } else {
                // Chores you still owe stay at the top until they are done.
                let current = items.filter { item in
                    item.kind == .chore || HouseholdInbox.timestamp(item.at).map { model.choreCalendar?.day($0) } == model.choreCalendar?.day()
                }
                let earlier = items.filter { item in !current.contains(item) }
                group("Today", current, read: read)
                group("Earlier", earlier, read: read)
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        if let all = read.readingAll(items) { Task { await model.markInboxRead(all) } }
                    } label: {
                        Label("Mark all read", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(model.busy || !items.contains(where: read.isUnread))
                    .accessibilityIdentifier("inbox-read-all")
                }
            }
        } else if let failure = model.inboxFailure {
            RoomFeedback(failure, identifier: "inbox-failure") {
                Button("Retry") { Task { await model.loadInbox() } }
                    .buttonStyle(RoomButtonStyle(kind: .secondary))
            }
        } else {
            Text("Loading notifications...")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                .accessibilityIdentifier("inbox-loading")
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [InboxItem], read: InboxReadState) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(RoomTheme.body(12).weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(RoomTheme.muted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items) { item in row(item, unread: read.isUnread(item)) }
            }
        }
    }

    private func row(_ item: InboxItem, unread: Bool) -> some View {
        let currency = model.state?.session?.household.currency
        let detail = item.detail + (item.amount.flatMap { amount in currency.map { "; " + Money.text(amount, currency: $0) } } ?? "")
        let (symbol, ink, soft): (String, Color, Color) = switch item.kind {
        case .chore: ("checklist", RoomTheme.error, RoomTheme.errorSoft)
        case .expense, .bill: ("receipt", RoomTheme.leaf, RoomTheme.leafSoft)
        case .settlement: ("wallet.bifold", RoomTheme.sunflower, RoomTheme.sunflowerSoft)
        }
        return Button { onOpen(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 32, height: 32)
                    .background(soft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(RoomTheme.body(14).weight(.semibold))
                    Text(detail).font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                if unread {
                    Circle().fill(RoomTheme.tomato).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RoomTheme.muted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(RoomTheme.ink)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(unread ? RoomTheme.errorBorder : RoomTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title). \(detail)")
        .accessibilityValue(unread ? "Unread" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("inbox-\(item.id)")
    }
}
