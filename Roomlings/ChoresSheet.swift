import RoomlingsCore
import SwiftUI

struct ChoresSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountModel
    @State private var section = Section.chores
    @State private var roomFilter = "kitchen"
    @State private var areaFilter = ""
    @State private var objectFilter = ""
    @State private var mine = false
    @State private var historyCount = 20
    @State private var adding = false
    @State private var editing: Chore?
    @State private var archiving: Chore?
    @State private var draft = ChoreFormValues()
    @State private var hasDraft = false
    @State private var confirming: Chore?
    @State private var undoing: ChoreCompletion?
    @State private var lastCompletionID: UUID?
    @State private var pending: Save?
    @State private var reviewRequired = false
    @State private var contentHeight: CGFloat = 480
    @State private var headerHeight: CGFloat = 64

    init(model: AccountModel, object: ChoreObject? = nil) {
        self.model = model
        _roomFilter = State(initialValue: object?.roomID ?? "kitchen")
        _areaFilter = State(initialValue: object?.area ?? "")
        _objectFilter = State(initialValue: object?.id ?? "")
    }

    private enum Section: String, CaseIterable, Identifiable {
        case chores = "Chores", history = "History", archived = "Archived"
        var id: String { rawValue }
    }

    private enum Change {
        case add(ChoreDraft), edit(Chore, ChoreDraft), archive(Chore, Bool), complete(Chore), undo(ChoreCompletion)
    }

    private struct Save {
        let householdID: UUID
        let version: Int64
        let mutationID = UUID()
        let change: Change
    }

    private var changesBlocked: Bool { model.busy || pending != nil || reviewRequired }
    private var dismissalBlocked: Bool { model.busy || pending != nil }
    private var title: String {
        if let editing { return editing.dueDate == nil ? "Schedule this chore again." : "Edit this chore." }
        if let archiving { return archiving.archived ? "Restore this chore?" : "Archive this chore?" }
        return adding ? "Add a household chore." : undoing != nil ? "Undo this chore completion?"
            : confirming != nil ? "Mark this chore done?" : "Household chores"
    }
    private var pageID: String {
        if adding { return "add" }
        if let editing { return "edit-\(editing.id)-\(editing.version)" }
        if let archiving { return "archive-\(archiving.id)" }
        if let undoing { return "undo-\(undoing.id.uuidString)" }
        return confirming?.id.uuidString ?? "board"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(RoomTheme.heading()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Done") { dismiss() }.disabled(dismissalBlocked)
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        feedback.id("chores-feedback")
                        if let chores = model.chores, let catalog = model.choreCatalog, let calendar = model.choreCalendar,
                           model.canUseAccount, model.state?.session != nil {
                            if adding || editing != nil {
                                form(chores: chores, catalog: catalog, calendar: calendar)
                            } else if let archiving {
                                archiveConfirmation(archiving, chores: chores, catalog: catalog, calendar: calendar)
                            } else if let undoing {
                                undoConfirmation(undoing, chores: chores, catalog: catalog, calendar: calendar)
                            } else if let confirming {
                                confirmation(confirming, chores: chores, catalog: catalog, calendar: calendar)
                            } else {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    board(chores, catalog: catalog, calendar: calendar, today: calendar.day(context.date))
                                }
                            }
                        } else {
                            RoomFeedback(model.choresFailure ?? "Open a household to use its chores.",
                                         identifier: "chores-unavailable")
                        }
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .id(pageID)
                .scrollDismissesKeyboard(.interactively)
                .disabled(model.busy)
                .onChange(of: model.message) { _, message in
                    if message != nil { proxy.scrollTo("chores-feedback", anchor: .top) }
                }
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { proxy.scrollTo("chores-feedback", anchor: .top) }
                }
            }
            .modifier(RoomSheetLoading(model: model, label: "Loading chores..."))
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .tint(RoomTheme.sage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chores-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(dismissalBlocked)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
    }

    @ViewBuilder private var feedback: some View {
        if model.busy {
            HStack {
                RoomBrandMark()
                Text(pending == nil ? "Refreshing chores..." : "Saving chores...")
            }
            .accessibilityIdentifier("chores-progress")
        }
        if let message = model.message {
            RoomFeedback(message, identifier: "chores-error")
        }
        if let notice = model.notice {
            Text(notice).foregroundStyle(RoomTheme.leaf).accessibilityIdentifier("chores-notice")
        }
        if undoing == nil, section != .history, let id = lastCompletionID, let chores = model.chores,
           let completion = chores.history.first(where: { $0.id == id }), chores.canUndo(completion) {
            Button("Undo completion") { openUndo(completion) }
                .buttonStyle(RoomButtonStyle(kind: .text))
                .disabled(changesBlocked)
        }
        if let pending, !model.busy {
            Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                .font(RoomTheme.body(14))
                .foregroundStyle(RoomTheme.muted)
            Button("Retry save") { Task { await send(pending) } }
                .buttonStyle(RoomButtonStyle(kind: .primary))
        }
        Button(pending != nil || reviewRequired ? "Review latest chores" : "Refresh chores") {
            Task {
                let uncertain = pending != nil
                let reviewing = uncertain || reviewRequired
                if await model.refresh(), model.chores != nil {
                    pending = nil
                    reviewRequired = false
                    if reviewing {
                        if uncertain || editing == nil {
                            adding = false
                            editing = nil
                        }
                        archiving = nil
                        confirming = nil
                        undoing = nil
                        model.notice = "Chores refreshed. Review the current list before starting another change."
                    }
                }
            }
        }
        .buttonStyle(RoomButtonStyle(kind: .text))
        .disabled(model.busy)
    }

    private func board(_ chores: HouseholdChores, catalog: ChoreCatalog, calendar: ChoreCalendar, today: String) -> some View {
        let filtered = chores.items.filter { matches(roomID: $0.roomID, area: $0.area, componentID: $0.componentID) }
            .filter { !mine || chores.assignee(for: $0)?.id == model.state?.session?.memberID }
        let scheduled = filtered.filter { !$0.archived && $0.dueDate != nil && !chores.isPaused($0) }
        let paused = filtered.filter { chores.isPaused($0) }
        let items = (section == .archived ? filtered.filter(\.archived) : scheduled + paused)
            .sorted {
                if $0.dueDate != $1.dueDate { return ($0.dueDate ?? "") < ($1.dueDate ?? "") }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        let history = chores.history.filter { matches(roomID: $0.roomID, area: $0.area, componentID: $0.componentID) }
            .filter { !mine || $0.completedBy == model.state?.session?.memberID || $0.assignedTo == model.state?.session?.memberID }
            .sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
        return VStack(alignment: .leading, spacing: 16) {
            RoomSegmentedPicker("Chore sections", selection: $section, options: Section.allCases) {
                $0.rawValue
            }
            .accessibilityIdentifier("chore-sections")
            filters(catalog: catalog)
            RoomSwitch(section == .history ? "My turns and completions" : "My turn only", isOn: $mine)
                .frame(minHeight: 44)
            if section == .history {
                if history.isEmpty {
                    emptyState("No completions yet.", detail: "Completed chores will be recorded here.")
                }
                ForEach(history.prefix(historyCount)) { completion in
                    completionCard(completion, chores: chores, catalog: catalog, calendar: calendar, today: today)
                }
                if history.count > historyCount {
                    Button("Show more completions") { historyCount += 20 }
                }
            } else {
                HStack {
                    let due = scheduled.filter { ($0.dueDate ?? "") <= today }.count
                    Text(section == .archived ? "\(items.count) archived"
                         : "\(due) due / \(scheduled.count) scheduled" + (paused.isEmpty ? "" : " / \(paused.count) paused in Storage"))
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    Spacer()
                    Button("Add chore") { openForm() }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(changesBlocked || chores.items.count >= 200)
                }
                if items.isEmpty {
                    emptyState(section == .archived ? "No archived chores." : mine ? "No chores assigned to you." : "No chores here yet.",
                               detail: section == .archived ? "Archived chores keep their completion history." : "Add a task or choose another room.")
                }
                ForEach(items) { chore in
                    choreCard(chore, chores: chores, catalog: catalog, today: today)
                }
            }
            if chores.items.count >= 200 {
                Text("This home has reached its 200-chore limit.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
        }
    }

    private func filters(catalog: ChoreCatalog) -> some View {
        let room = catalog.rooms.first { $0.id == roomFilter }
        let objects = model.choreObjects.filter {
            (roomFilter == "all" || $0.roomID == roomFilter) && (areaFilter.isEmpty || $0.area == areaFilter)
        }
        return VStack(alignment: .leading, spacing: 12) {
            RoomPickerField("Chore room", selectedLabel: roomFilter == "all" ? "All rooms"
                        : catalog.location(roomID: roomFilter == "home" ? nil : roomFilter, area: nil),
                        selection: Binding(get: { roomFilter }, set: {
                roomFilter = $0
                areaFilter = ""
                objectFilter = ""
            })) {
                Text("All rooms").tag("all")
                Text("Whole home").tag("home")
                ForEach(catalog.rooms) { room in Text(room.name).tag(room.id) }
            }
            if let room {
                RoomPickerField("Chore area", selectedLabel: areaFilter.isEmpty ? "All areas"
                            : room.areas.first(where: { $0.id == areaFilter })?.label ?? "Unavailable area",
                            selection: Binding(get: { areaFilter }, set: {
                    areaFilter = $0
                    objectFilter = ""
                })) {
                    Text("All areas").tag("")
                    ForEach(room.areas) { area in Text(area.label).tag(area.id) }
                }
            }
            if roomFilter != "home" {
                RoomPickerField("Chore object", selectedLabel: objectFilter.isEmpty ? "All objects and room chores"
                            : objects.first(where: { $0.id == objectFilter }).map {
                                $0.displayName(in: objects) + ($0.installed ? "" : " (Storage)")
                            } ?? "Unavailable object",
                            selection: Binding(get: { objectFilter }, set: { id in
                    objectFilter = id
                    if let object = model.choreObjects.first(where: { $0.id == id }) {
                        roomFilter = object.roomID
                        areaFilter = object.area ?? ""
                    }
                })) {
                    Text("All objects and room chores").tag("")
                    if !objectFilter.isEmpty && !objects.contains(where: { $0.id == objectFilter }) {
                        Text("Unavailable object").tag(objectFilter)
                    }
                    ForEach(objects) { object in
                        Text((roomFilter == "all" ? "\(catalog.location(roomID: object.roomID, area: nil)): " : "")
                             + object.displayName(in: objects) + (object.installed ? "" : " (Storage)")).tag(object.id)
                    }
                }
            }
        }
    }

    private func choreCard(_ chore: Chore, chores: HouseholdChores, catalog: ChoreCatalog, today: String) -> some View {
        let paused = chores.isPaused(chore)
        let assignee = chores.assignee(for: chore)
        let currentStatus = try? chore.status(on: today)
        let status = paused ? "Paused in Storage" : currentStatus == .due ? "Due today"
            : currentStatus?.rawValue.capitalized ?? "Status unavailable"
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    Text(chore.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
                    Spacer(minLength: 8)
                    badge(status)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(chore.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
                    badge(status)
                }
            }
            Text(location(chore, catalog: catalog))
            if paused {
                Text("This object's care is paused in Storage. Bring it back on the web to resume. Its due date, rotation and completion history are kept.")
            } else if chore.archived && !chores.canRestore(chore) {
                Text("This object is in Storage. Bring it back on the web before restoring this chore. Its history is kept.")
            }
            HStack {
                Text(chore.dueDate.map { ChoreCalendar.title($0, today: today) } ?? "One-off completed")
                Spacer()
                Text(ChoreCalendar.repeats(chore.repeatDays))
            }
            if !chore.notes.isEmpty { Text(chore.notes) }
            HStack {
                Text(assignee.map { $0.id == model.state?.session?.memberID ? "Your turn" : "\($0.name)'s turn" }
                     ?? "Unassigned. Choose an active roommate.")
                Spacer()
                if chore.rotation.count > 1 { Text("Rotating") }
            }
            if chore.archived {
                Button("Restore chore") { openArchive(chore) }
                    .disabled(changesBlocked || !chores.canRestore(chore))
            } else {
                HStack(spacing: 8) {
                    Button("Mark done") {
                        model.clearFeedback()
                        confirming = chore
                    }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .disabled(changesBlocked || chore.dueDate == nil || paused || currentStatus == nil)
                    Button { openForm(chore) } label: {
                        Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .accessibilityLabel("Edit \(chore.title)")
                    .disabled(changesBlocked || !chores.canEdit(chore))
                    Button { openArchive(chore) } label: {
                        Image(systemName: "archivebox").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .accessibilityLabel("Archive \(chore.title)")
                    .disabled(changesBlocked)
                }
            }
        }
        .font(RoomTheme.body(14))
        .foregroundStyle(RoomTheme.muted)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chore-\(chore.id.uuidString.lowercased())")
    }

    private func completionCard(_ completion: ChoreCompletion, chores: HouseholdChores, catalog: ChoreCatalog,
                                calendar: ChoreCalendar, today: String) -> some View {
        let object = model.choreObjects.first { $0.id == completion.componentID }
        return VStack(alignment: .leading, spacing: 12) {
            Text(completion.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            badge(completion.undoneAt == nil ? "Done" : "Undone")
            Text(catalog.location(roomID: completion.roomID, area: completion.area,
                                  componentName: completion.componentName ?? object?.name))
            Text("\(memberName(completion.completedBy, chores: chores)) completed it on \(ChoreCalendar.title(calendar.completionDay(completion.completedAt), today: today)).")
            Text("Scheduled for \(ChoreCalendar.title(completion.dueDate, today: today)).")
            if let assignee = completion.assignedTo { Text("Assigned to \(memberName(assignee, chores: chores)).") }
            if let undoneBy = completion.undoneBy { Text("Undone by \(memberName(undoneBy, chores: chores)).") }
            if chores.canUndo(completion) {
                Button("Undo completion") { openUndo(completion) }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(changesBlocked)
            }
            if chores.canScheduleAgain(completion), let chore = chores.items.first(where: { $0.id == completion.choreID }) {
                Button("Schedule again") { openForm(chore) }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(changesBlocked || !chores.canEdit(chore))
            }
        }
        .font(RoomTheme.body(14))
        .foregroundStyle(RoomTheme.muted)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("completion-\(completion.id.uuidString.lowercased())")
    }

    private func confirmation(_ chore: Chore, chores: HouseholdChores, catalog: ChoreCatalog, calendar: ChoreCalendar) -> some View {
        let current = chores.items.first { $0.id == chore.id }
        let allowed = current.map { $0.version == chore.version && !$0.archived && $0.dueDate != nil && !chores.isPaused($0) } ?? false
        return VStack(alignment: .leading, spacing: 16) {
            Text("This records a completed turn, not a payment.").foregroundStyle(RoomTheme.muted)
            Text(chore.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(location(chore, catalog: catalog))
            if let due = chore.dueDate { Text("Scheduled for \(ChoreCalendar.title(due, today: calendar.day())).") }
            if let assignee = chores.assignee(for: chore) { Text("Assigned to \(assignee.name).") }
            if let memberID = model.state?.session?.memberID {
                Text("Completion will be recorded by \(memberName(memberID, chores: chores)).")
            }
            if !allowed {
                RoomFeedback("Chore changed or its object is unavailable. Close this sheet and review the latest chores.")
            }
            Button("Record completion") { start(.complete(chore)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(changesBlocked || !allowed)
            Button("Cancel") { confirming = nil; model.clearFeedback() }.disabled(dismissalBlocked)
        }
    }

    private func form(chores: HouseholdChores, catalog: ChoreCatalog, calendar: ChoreCalendar) -> some View {
        let latest = editing.flatMap { snapshot in chores.items.first { $0.id == snapshot.id } }
        let blocked = editing != nil && (latest == nil || latest.map { !chores.canEdit($0) } == true)
        let changed = editing != nil && latest?.version != editing?.version
        return VStack(alignment: .leading, spacing: 20) {
            if blocked {
                RoomFeedback("Chore unavailable, archived or paused in Storage. Cancel and review the latest chores.")
            } else if changed, let latest {
                RoomFeedback("This chore changed. Review its latest schedule before saving your draft.")
                Text("Latest: \(latest.title). \(latest.dueDate.map { ChoreCalendar.title($0, today: calendar.day()) } ?? "One-off completed"). \(ChoreCalendar.repeats(latest.repeatDays)).")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Button("Use latest chore") { openForm(latest) }.disabled(changesBlocked)
                Button("Keep my draft") { editing = latest; model.clearFeedback() }.disabled(changesBlocked)
            }
            ChoreForm(values: $draft, chores: chores, catalog: catalog, objects: model.choreObjects,
                      calendar: calendar, disabled: changesBlocked, editing: editing != nil,
                      submitDisabled: blocked || changed) { value in
                start(editing.map { .edit($0, value) } ?? .add(value))
            }
            Button("Cancel") {
                adding = false
                editing = nil
                model.clearFeedback()
            }
            .disabled(dismissalBlocked)
        }
    }

    private func archiveConfirmation(_ chore: Chore, chores: HouseholdChores,
                                     catalog: ChoreCatalog, calendar: ChoreCalendar) -> some View {
        let latest = chores.items.first { $0.id == chore.id }
        let allowed = latest.map {
            $0.version == chore.version && $0.archived == chore.archived && (!chore.archived || chores.canRestore($0))
        } ?? false
        return VStack(alignment: .leading, spacing: 16) {
            Text(chore.archived ? "The chore returns with its saved schedule. Previous history stays."
                 : "The chore leaves the active list. Its history stays, and it can be restored later. Archiving does not free a chore slot.")
                .foregroundStyle(RoomTheme.muted)
            Text(chore.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(location(chore, catalog: catalog))
            if let due = chore.dueDate { Text("Scheduled for \(ChoreCalendar.title(due, today: calendar.day())).") }
            if !allowed {
                RoomFeedback("Chore changed or its object is unavailable. Cancel and review the latest chores.")
            }
            Button(chore.archived ? "Restore chore" : "Archive chore") { start(.archive(chore, !chore.archived)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(changesBlocked || !allowed)
            Button("Cancel") { archiving = nil; model.clearFeedback() }.disabled(dismissalBlocked)
        }
    }

    private func undoConfirmation(_ completion: ChoreCompletion, chores: HouseholdChores,
                                  catalog: ChoreCatalog, calendar: ChoreCalendar) -> some View {
        let allowed = chores.canUndo(completion)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Restore the previous due date and turn. A later edit or completion cannot be overwritten.")
                .foregroundStyle(RoomTheme.muted)
            Text(completion.title).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(catalog.location(roomID: completion.roomID, area: completion.area,
                                  componentName: completion.componentName))
            Text("Scheduled for \(ChoreCalendar.title(completion.dueDate, today: calendar.day())).")
            if !allowed {
                RoomFeedback("Chore changed. This completion can no longer be undone.")
            }
            Button("Keep completion") { undoing = nil; model.clearFeedback() }
                .disabled(dismissalBlocked)
            Button("Undo completion") { start(.undo(completion)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(changesBlocked || !allowed)
        }
    }

    private func badge(_ text: String) -> some View {
        let due = text == "Due today" || text == "Overdue" || text == "Status unavailable"
        let completed = text == "Completed" || text == "Done"
        let upcoming = text == "Upcoming"
        return Text(text)
            .font(RoomTheme.body(12))
            .foregroundStyle(due ? RoomTheme.error : completed ? RoomTheme.leaf : upcoming ? RoomTheme.sky : RoomTheme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(due ? RoomTheme.errorSoft : completed ? RoomTheme.leafSoft : upcoming ? RoomTheme.skySoft : RoomTheme.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: 5))
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(RoomTheme.heading(20))
            Text(detail).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
        }
        .padding(.vertical, 16)
    }

    private func matches(roomID: String?, area: String?, componentID: String?) -> Bool {
        guard roomFilter == "all" || (roomFilter == "home" ? roomID == nil : roomID == roomFilter) else { return false }
        if !objectFilter.isEmpty {
            if componentID == objectFilter { return true }
            guard componentID == nil, let object = model.choreObjects.first(where: { $0.id == objectFilter }),
                  object.id == "default-\(object.slotID)", let objectArea = object.area else { return false }
            return roomID == object.roomID && area == objectArea
        }
        return areaFilter.isEmpty || area == areaFilter
    }

    private func location(_ chore: Chore, catalog: ChoreCatalog) -> String {
        let object = model.choreObjects.first { $0.id == chore.componentID }
        return catalog.location(roomID: chore.roomID, area: chore.area,
                                componentName: chore.archived ? chore.componentName ?? object?.name : object?.name ?? chore.componentName)
    }

    private func memberName(_ id: UUID, chores: HouseholdChores) -> String {
        chores.members.first(where: { $0.id == id })?.name ?? "Former roommate"
    }

    private func openUndo(_ completion: ChoreCompletion) {
        model.clearFeedback()
        adding = false
        editing = nil
        archiving = nil
        confirming = nil
        undoing = completion
    }

    private func openArchive(_ chore: Chore) {
        model.clearFeedback()
        archiving = chore
    }

    private func openForm(_ chore: Chore? = nil) {
        guard let memberID = model.state?.session?.memberID else {
            model.message = "Open your household before adding a chore."
            return
        }
        if let chore {
            guard let calendar = model.choreCalendar else {
                model.message = "Refresh chores before editing their saved schedule."
                return
            }
            do {
                draft = try ChoreFormValues(chore: chore, calendar: calendar)
                hasDraft = false
            } catch {
                model.message = "The saved chore date could not be loaded. Refresh chores before editing it."
                return
            }
        } else if !hasDraft {
            draft = ChoreFormValues()
            draft.roomID = roomFilter == "home" ? "" : roomFilter == "all" ? "kitchen" : roomFilter
            draft.area = areaFilter
            if model.choreObjects.contains(where: { $0.id == objectFilter && $0.installed }) { draft.componentID = objectFilter }
            draft.rotation = [memberID]
            draft.nextMemberID = memberID
            hasDraft = true
        }
        model.clearFeedback()
        adding = chore == nil
        editing = chore
        archiving = nil
        confirming = nil
        undoing = nil
    }

    private func start(_ change: Change) {
        guard !changesBlocked, let household = model.state?.session?.household else {
            model.message = "Refresh chores and finish the current save before starting another change."
            return
        }
        if case .undo(let completion) = change, model.chores?.canUndo(completion) != true {
            model.message = "This completion changed. Refresh chores and review the latest history."
            reviewRequired = true
            return
        }
        switch change {
        case .edit(let chore, _), .archive(let chore, _):
            guard let latest = model.chores?.items.first(where: { $0.id == chore.id }), latest.version == chore.version else {
                model.message = "This chore changed. Refresh chores and review the latest schedule."
                reviewRequired = true
                return
            }
        default: break
        }
        let save = Save(householdID: household.id, version: household.version, change: change)
        pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        let saved: Bool
        switch save.change {
        case .add(let draft):
            saved = await model.addChore(draft, householdID: save.householdID, version: save.version, mutationID: save.mutationID)
        case .edit(let chore, let draft):
            saved = await model.editChore(chore, draft: draft, householdID: save.householdID,
                                          version: save.version, mutationID: save.mutationID)
        case .archive(let chore, let archived):
            saved = await model.setChoreArchived(chore, archived: archived, householdID: save.householdID,
                                                 version: save.version, mutationID: save.mutationID)
        case .complete(let chore):
            saved = await model.completeChore(chore, householdID: save.householdID, version: save.version, mutationID: save.mutationID)
        case .undo(let completion):
            saved = await model.undoChoreCompletion(completion, householdID: save.householdID,
                                                   version: save.version, mutationID: save.mutationID)
        }
        if saved {
            pending = nil
            reviewRequired = false
            adding = false
            editing = nil
            archiving = nil
            confirming = nil
            undoing = nil
            switch save.change {
            case .archive: break
            default: section = .chores
            }
            switch save.change {
            case .add, .edit:
                draft = ChoreFormValues()
                hasDraft = false
                lastCompletionID = nil
            case .complete(let chore):
                lastCompletionID = model.chores?.history.first {
                    $0.choreID == chore.id && $0.occurrence == chore.occurrence
                        && $0.resultVersion == chore.version + 1 && $0.undoneAt == nil
                }?.id
            case .undo, .archive:
                lastCompletionID = nil
            }
        } else {
            switch model.choreSaveFailure {
            case .retrySameChange: pending = save
            case .refreshRequired: pending = nil; reviewRequired = true
            case .none: pending = nil
            }
        }
    }
}
