import RoomlingsCore
import SwiftUI

struct AccountRoomStyleSection: View {
    /// The selection lives with the sheet because account refreshes replace the sheet's content.
    struct Form {
        var selected: String?
        var opened: String?
        var pending: Save?
        var reviewRequired = false
    }

    struct Save {
        let householdID: UUID
        let version: Int64
        let mutationID = UUID()
        let style: String
    }

    @Bindable var model: AccountModel
    @Binding var form: Form
    let onSaved: () -> Void

    private var changesBlocked: Bool { model.busy || form.pending != nil || form.reviewRequired }

    var body: some View {
        AccountSection("Room style") {
            if let current = model.roomStyle, let catalog = model.roomStyleCatalog,
               let household = model.state?.session?.household {
                let selected = form.selected ?? current.style
                Text("One shared look for everyone.")
                    .foregroundStyle(RoomTheme.muted)
                ForEach(catalog.styles) { style in
                    option(style, selected: selected == style.id, current: current.style == style.id)
                }
                Text(hint(current: current.style, catalog: catalog))
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    .accessibilityIdentifier("room-style-hint")
                if let pending = form.pending, !model.busy {
                    Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    Button("Retry save") { Task { await send(pending) } }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                }
                if form.pending != nil || form.reviewRequired {
                    Button("Review latest room style") { Task { await review() } }
                        .accessibilityIdentifier("review-room-style")
                } else {
                    Button(model.busy ? "Saving..." : "Apply for everyone") {
                        start(selected, household: household, current: current)
                    }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .disabled(model.busy || !model.canEditRoom || selected == current.style)
                    .accessibilityIdentifier("apply-room-style")
                }
            } else {
                Text(model.roomStyleFailure ?? "Open a household to change its room style.")
                Button("Refresh account") { Task { await review() } }
            }
        }
        .onAppear {
            if form.opened == nil, let current = model.roomStyle {
                form.opened = current.style
                form.selected = current.style
            }
        }
    }

    private func option(_ style: RoomStyleCatalog.Style, selected: Bool, current: Bool) -> some View {
        Button {
            form.selected = style.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? RoomTheme.sage : RoomTheme.muted)
                        .accessibilityHidden(true)
                    Text(style.name).font(RoomTheme.body().weight(.semibold))
                    if current {
                        Text("Current").font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                swatches(style.colors)
                Text(style.description)
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RoomTheme.leafSoft : RoomTheme.surface,
                        in: RoundedRectangle(cornerRadius: RoomTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius)
                .stroke(selected ? RoomTheme.sage : RoomTheme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(changesBlocked || !model.canEditRoom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current ? "\(style.name), current" : style.name)
        .accessibilityHint(style.description)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("room-style-\(style.id)")
    }

    private func swatches(_ colors: RoomStyleCatalog.Style.Colors) -> some View {
        HStack(spacing: 4) {
            swatch(colors.wall)
            // The web floor swatch is a two-tone checkerboard.
            VStack(spacing: 0) {
                HStack(spacing: 0) { tile(colors.floor); tile(colors.floorAlternate) }
                HStack(spacing: 0) { tile(colors.floorAlternate); tile(colors.floor) }
            }
            .frame(width: 28, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RoomTheme.border, lineWidth: 1))
            swatch(colors.fridgeDoor)
            swatch(colors.cabinetPanel)
            swatch(colors.counter)
            swatch(colors.lightWood)
        }
        .accessibilityHidden(true)
    }

    private func swatch(_ hex: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(fill(hex))
            .frame(width: 28, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RoomTheme.border, lineWidth: 1))
    }

    private func tile(_ hex: String) -> some View {
        Rectangle().fill(fill(hex)).frame(width: 14, height: 10)
    }

    private func fill(_ hex: String) -> Color {
        HouseholdMemberColor(hex: hex).map(RoomTheme.member) ?? .clear
    }

    private func hint(current: String, catalog: RoomStyleCatalog) -> String {
        var text = "Current shared look: \(catalog.style(current)?.name ?? current)."
        if let opened = form.opened, opened != current {
            text += " The room changed while this picker was open. Review your selection before applying."
        }
        text += " Your selection is not shared until you apply it."
        if !model.canEditRoom {
            text += " Only a household owner or admin can apply a shared style. Ask an admin for room editing access."
        }
        return text
    }

    private func start(_ style: String, household: HouseholdSnapshot, current: HouseholdRoomStyle) {
        guard !changesBlocked, model.canEditRoom, style != current.style else { return }
        let save = Save(householdID: household.id, version: household.version, style: style)
        form.pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        if await model.saveRoomStyle(save.style, householdID: save.householdID, version: save.version, mutationID: save.mutationID) {
            form.pending = nil
            onSaved()
            return
        }
        switch model.roomStyleSaveFailure {
        case .retrySameChange: form.pending = save
        case .refreshRequired: form.pending = nil; form.reviewRequired = true
        case .none: form.pending = nil
        }
    }

    private func review() async {
        let uncertain = form.pending != nil
        guard await model.refresh(), let current = model.roomStyle else { return }
        form.pending = nil
        form.reviewRequired = false
        form.opened = current.style
        // An unconfirmed save may have landed, so the picker shows what the server holds.
        if uncertain || form.selected == nil { form.selected = current.style }
        model.notice = "Room style refreshed. Review your selection before applying."
    }
}
