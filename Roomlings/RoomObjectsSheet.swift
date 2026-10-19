import RoomlingsCore
import SwiftUI

/// The objects in the current room, matching the web's Room objects panel (`src/RoomComponents.tsx`):
/// details, manual state, supply shortcuts and linked chores for each object.
struct RoomObjectsSheet: View {
    enum Route {
        case chores(objectID: String), addChore(objectID: String, routine: RoomObjectCatalog.Routine?)
        case roomChores, shopping, receipts, balances
    }

    private enum Change {
        case state(RoomObject, String?), restock(RoomObject, RoomObject.Supply, ShoppingDraft)
    }

    private struct Save {
        let householdID: UUID
        let version: Int64
        let mutationID = UUID()
        let change: Change
    }

    private struct Restock {
        let object: RoomObject
        let supply: RoomObject.Supply
        var name: String
        var quantity: String
        var notes: String
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountModel
    let roomID: String
    let onOpen: (Route) -> Void
    @State private var selectedID: String?
    @State private var restock: Restock?
    @State private var pending: Save?
    @State private var reviewRequired = false
    @State private var contentHeight: CGFloat = 480
    @State private var headerHeight: CGFloat = 64

    private var changesBlocked: Bool { model.busy || pending != nil || reviewRequired }
    private var roomName: String {
        model.choreCatalog?.rooms.first { $0.id == roomID }?.name ?? "Room"
    }
    private var objects: [RoomObject] {
        model.roomObjects.filter { $0.installed && $0.roomID == roomID }
    }

    var body: some View {
        VStack(spacing: 0) {
            RoomSheetHeader(title: restock == nil ? "\(roomName) objects" : "Restock a household supply.") {
                Button("Done") { dismiss() }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(model.busy || pending != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        feedback.id("objects-feedback")
                        content
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.message) { _, message in
                    if message != nil { proxy.scrollTo("objects-feedback", anchor: .top) }
                }
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { proxy.scrollTo("objects-feedback", anchor: .top) }
                }
            }
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .tint(RoomTheme.sage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-objects-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(model.busy || pending != nil)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
    }

    @ViewBuilder private var feedback: some View {
        if model.busy {
            HStack {
                RoomBrandMark()
                Text(pending == nil ? "Refreshing room objects..." : "Saving...")
            }
            .accessibilityIdentifier("objects-progress")
        }
        if let message = model.message {
            RoomFeedback(message, identifier: "objects-error")
        }
        if let notice = model.notice {
            Text(notice).foregroundStyle(RoomTheme.leaf).accessibilityIdentifier("objects-notice")
        }
        if let pending, !model.busy {
            VStack(alignment: .leading, spacing: 8) {
                Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Button("Retry save") { Task { await send(pending) } }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
            }
        }
        if pending != nil || reviewRequired {
            Button("Review latest objects") { Task { await review() } }
                .disabled(model.busy)
                .accessibilityIdentifier("review-room-objects")
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.roomObjectsFailure {
            Text(failure).foregroundStyle(RoomTheme.muted)
        } else if let catalog = model.roomObjectCatalog {
            if let restock {
                restockForm(restock)
            } else if let selected = objects.first(where: { $0.id == selectedID }) {
                details(selected, catalog: catalog)
            } else {
                if selectedID != nil {
                    RoomFeedback("This object is in Storage or unavailable. Shopping entries and chore history are kept.")
                }
                list(catalog: catalog)
            }
        } else {
            Text("Open a household to see its room objects.").foregroundStyle(RoomTheme.muted)
        }
    }

    // MARK: - All objects

    private func list(catalog: RoomObjectCatalog) -> some View {
        var groups: [(kind: String, items: [RoomObject])] = []
        for object in objects {
            if let index = groups.firstIndex(where: { $0.kind == object.kind }) {
                groups[index].items.append(object)
            } else {
                groups.append((object.kind, [object]))
            }
        }
        return VStack(spacing: 10) {
            if groups.isEmpty {
                Text("No objects are placed in this room.").foregroundStyle(RoomTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(groups, id: \.kind) { group in
                let first = group.items[0]
                let label = group.items.count > 1 ? catalog.kinds[group.kind]?.name ?? first.name : first.name
                let status = group.items.count == 1 ? statusLabel(first, catalog: catalog) : ""
                Button {
                    model.clearFeedback()
                    selectedID = first.id
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label).font(RoomTheme.body(16).weight(.bold)).foregroundStyle(RoomTheme.leaf)
                            if group.items.count > 1 { detail("\(group.items.count) objects") }
                            if !status.isEmpty { detail(status) }
                            detail(catalog.kinds[group.kind]?.description ?? "")
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RoomTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .accessibilityLabel("Open \(label) details")
                .accessibilityIdentifier("room-object-\(first.id)")
            }
        }
    }

    // MARK: - One object

    @ViewBuilder private func details(_ object: RoomObject, catalog: RoomObjectCatalog) -> some View {
        let kind = catalog.kinds[object.kind]
        let positions = objects.filter { $0.kind == object.kind }
        Button {
            model.clearFeedback()
            selectedID = nil
        } label: {
            Label("All room objects", systemImage: "arrow.left")
        }
        .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
        .disabled(model.busy)
        Text(object.name).font(RoomTheme.heading(24)).accessibilityAddTraits(.isHeader)
        if positions.count > 1 {
            RoomSegmentedPicker("\(kind?.name ?? object.name) objects",
                                selection: Binding(get: { object.id }, set: { selectedID = $0 }),
                                options: positions.map(\.id)) { id in
                positions.first { $0.id == id }.map { RoomObjectCatalog.displayName($0, among: objects) } ?? id
            }
            .disabled(model.busy)
        }
        if (kind?.variants.count ?? 0) > 1 || object.finish != "room" {
            VStack(alignment: .leading, spacing: 4) {
                if (kind?.variants.count ?? 0) > 1 { pair("Model", catalog.modelName(object)) }
                if object.finish != "room" { pair("Color", catalog.finishName(object)) }
            }
        }
        if let shortcut = RoomObjectCatalog.shortcuts[object.kind] {
            Button(shortcut) { useShortcut(object) }
                .disabled(model.busy)
        }
        if let states = kind?.states, !states.isEmpty {
            section("Manual state") {
                RoomPickerField("Manual state", selectedLabel: catalog.stateName(object) ?? "Not set",
                                selection: Binding(get: { object.state ?? "" }, set: { value in
                    let state = value.isEmpty ? nil : value
                    if state != object.state { start(.state(object, state)) }
                })) {
                    Text("Not set").tag("")
                    ForEach(states, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(changesBlocked)
                detail("Manual status only. No appliance control, chore completion or payment.")
                if let changedAt = object.stateChangedAt, let calendar = model.choreCalendar {
                    let name = model.chores?.members.first { $0.id == object.stateChangedBy }?.name ?? "a former roommate"
                    detail("Last set by \(name) on \(ChoreCalendar.title(calendar.completionDay(changedAt), today: calendar.day())).")
                }
            }
        }
        section("Supply shortcuts") {
            if object.supplies.isEmpty {
                detail("No supplies set. \(model.canEditRoom ? "Add them on the web in Edit room." : "An admin can add them.")")
            } else {
                detail("Shared shopping shortcuts, not stock tracking.")
                ForEach(object.supplies) { supply in supplyRow(object, supply: supply) }
                if object.kind != "shopping-bag" {
                    Button { open(.shopping) } label: { Label("Open shopping list", systemImage: "basket") }
                        .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                        .disabled(model.busy)
                }
            }
        }
        choresSection(object, routines: kind?.chores ?? [])
    }

    private func supplyRow(_ object: RoomObject, supply: RoomObject.Supply) -> some View {
        let listed = model.shopping?.items.first {
            ShoppingRestock.normalized($0.name) == ShoppingRestock.normalized(supply.name)
        }
        let full = (model.shopping?.items.count ?? 0) >= 200
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(supply.name).font(RoomTheme.body(15).weight(.semibold))
                detail(listed.map { "\($0.quantity) already on the shared list" } ?? supply.quantity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if listed != nil {
                Label("On the list", systemImage: "checkmark")
                    .font(RoomTheme.body(12))
                    .foregroundStyle(RoomTheme.leaf)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoomTheme.leafSoft, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button("Add to list") {
                    model.clearFeedback()
                    restock = Restock(object: object, supply: supply, name: supply.name, quantity: supply.quantity,
                                      notes: "\(roomName): \(object.name)")
                }
                .buttonStyle(RoomButtonStyle(size: 14))
                .fixedSize()
                .disabled(changesBlocked || full)
                .accessibilityLabel("Restock \(supply.name)")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func choresSection(_ object: RoomObject, routines: [RoomObjectCatalog.Routine]) -> some View {
        let area = model.choreObjects.first { $0.id == object.id }?.area
        let linked = (model.chores?.items ?? []).filter { chore in
            guard !chore.archived else { return false }
            if let componentID = chore.componentID { return componentID == object.id }
            return object.id == "default-\(object.slotID)" && area != nil && chore.roomID == object.roomID && chore.area == area
        }
        .sorted { ($0.dueDate ?? "9999", $0.title) < ($1.dueDate ?? "9999", $1.title) }
        let suggestions = routines.filter { routine in
            !linked.contains { ShoppingRestock.normalized($0.title) == ShoppingRestock.normalized(routine.title) }
        }
        let full = (model.chores?.items.count ?? 0) >= 200
        section("Chores") {
            if linked.isEmpty {
                detail("No chores yet. Add one or choose a routine.")
            } else if let chores = model.chores, let calendar = model.choreCalendar {
                let today = calendar.day()
                ForEach(linked) { chore in
                    let status = (try? chore.status(on: today)).map { $0 == .due ? "Due today" : $0.rawValue.capitalized }
                        ?? "Status unavailable"
                    let assignee = chores.assignee(for: chore)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(chore.title).font(RoomTheme.body(15).weight(.semibold))
                            Spacer(minLength: 8)
                            badge(status)
                        }
                        detail((chore.dueDate.map { ChoreCalendar.title($0, today: today) } ?? "One-off completed")
                               + (assignee.map { "; \($0.name)'s turn" } ?? "; unassigned"))
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack(spacing: 8) {
                if !linked.isEmpty {
                    Button("Open object chores") { open(.chores(objectID: object.id)) }
                        .buttonStyle(RoomButtonStyle(size: 14))
                        .disabled(model.busy)
                }
                Button("Add chore") { open(.addChore(objectID: object.id, routine: nil)) }
                    .buttonStyle(RoomButtonStyle(size: 14))
                    .disabled(model.busy || full)
            }
            if !suggestions.isEmpty {
                Text("Suggested routines").font(RoomTheme.body(14).weight(.semibold)).padding(.top, 4)
                ForEach(suggestions, id: \.title) { routine in
                    Button { open(.addChore(objectID: object.id, routine: routine)) } label: {
                        Label(routine.title, systemImage: "plus")
                    }
                    .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                    .disabled(model.busy || full)
                    .accessibilityLabel("Add \(routine.title)")
                }
            }
            if full { detail("This home has reached its 200-chore limit.") }
        }
    }

    // MARK: - Restock review

    @ViewBuilder private func restockForm(_ value: Restock) -> some View {
        let binding = Binding(get: { restock ?? value }, set: { restock = $0 })
        Text("Review the quantity before adding it to the shared shopping list.")
            .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
        RoomField("Item name", text: binding.name)
        RoomField("Quantity", text: binding.quantity)
        RoomField("Notes", text: binding.notes, axis: .vertical)
        HStack(spacing: 8) {
            Button("Cancel") {
                model.clearFeedback()
                restock = nil
            }
            .disabled(model.busy || pending != nil)
            Button(model.busy ? "Saving..." : "Add item") {
                do {
                    let draft = try ShoppingDraft(name: value.name, quantity: value.quantity, notes: value.notes)
                    start(.restock(value.object, value.supply, draft))
                } catch {
                    model.message = "Check the item name and quantity, then try again."
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(changesBlocked)
        }
    }

    // MARK: - Saving

    private func start(_ change: Change) {
        guard !changesBlocked, let household = model.state?.session?.household else {
            model.message = "Refresh your account and finish the current save before starting another change."
            return
        }
        model.clearFeedback()
        let save = Save(householdID: household.id, version: household.version, change: change)
        pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        let saved: Bool
        let failure: AccountModel.HouseholdSaveFailure
        switch save.change {
        case .state(let object, let state):
            saved = await model.setRoomObjectState(object, state: state, householdID: save.householdID,
                                                   version: save.version, mutationID: save.mutationID)
            failure = model.roomObjectSaveFailure
        case .restock(let object, let supply, let draft):
            saved = await model.restock(object, supply: supply, draft: draft, householdID: save.householdID,
                                        version: save.version, mutationID: save.mutationID)
            failure = model.shoppingSaveFailure
        }
        if saved {
            pending = nil
            if case .restock = save.change { restock = nil }
            return
        }
        switch failure {
        case .retrySameChange: pending = save
        case .refreshRequired: pending = nil; reviewRequired = true
        case .none: pending = nil
        }
    }

    private func review() async {
        guard await model.refresh() else { return }
        pending = nil
        reviewRequired = false
        restock = nil
        model.notice = "Room objects refreshed. Review the latest state before changing it again."
    }

    // MARK: - Routing and pieces

    private func useShortcut(_ object: RoomObject) {
        switch object.kind {
        case "shopping-bag": open(.shopping)
        case "receipt-book": open(.receipts)
        case "settlement-envelope": open(.balances)
        case "cleaning-caddy": open(.roomChores)
        default: model.message = "Use this object through its supplies, chores or state controls."
        }
    }

    private func open(_ route: Route) {
        guard !model.busy else { return }
        model.clearFeedback()
        onOpen(route)
    }

    private func statusLabel(_ object: RoomObject, catalog: RoomObjectCatalog) -> String {
        if let state = catalog.stateName(object) { return "Manual state: \(state)" }
        if object.kind == "shopping-bag" { return "\(model.shopping?.items.count ?? 0) on the shared shopping list" }
        if object.kind == "noticeboard" {
            return "\(model.chores?.members.filter { !$0.inactive }.count ?? 0) roommates"
        }
        let area = model.choreObjects.first { $0.id == object.id }?.area
        let scheduled = (model.chores?.items ?? []).filter { chore in
            guard !chore.archived, chore.dueDate != nil else { return false }
            if let componentID = chore.componentID { return componentID == object.id }
            return object.id == "default-\(object.slotID)" && area != nil && chore.roomID == object.roomID && chore.area == area
        }
        guard !scheduled.isEmpty, let today = model.choreCalendar?.day() else { return "" }
        let due = scheduled.filter { ($0.dueDate ?? "9999") <= today }.count
        return "\(due) due / \(scheduled.count) scheduled chores"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(RoomTheme.border).frame(height: 1).padding(.bottom, 4)
            Text(title).font(RoomTheme.body(17).weight(.semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pair(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
            Text(value).font(RoomTheme.body(13).weight(.semibold))
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func badge(_ text: String) -> some View {
        let due = text == "Due today" || text == "Overdue" || text == "Status unavailable"
        let upcoming = text == "Upcoming"
        return Text(text)
            .font(RoomTheme.body(12))
            .foregroundStyle(due ? RoomTheme.error : upcoming ? RoomTheme.sky : RoomTheme.leaf)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(due ? RoomTheme.errorSoft : upcoming ? RoomTheme.skySoft : RoomTheme.leafSoft,
                        in: RoundedRectangle(cornerRadius: 5))
    }
}
