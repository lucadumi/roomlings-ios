import RoomlingsCore
import SwiftUI

/// Edit room, matching the web's room editor (`src/RoomComponents.tsx`): the objects in this room, the catalog
/// to add from, and Storage. Changes stay in a private draft until Apply for everyone.
struct RoomEditorSheet: View {
    @Bindable var model: AccountModel
    @Bindable var editor: RoomEditor
    let thumbnails: RoomThumbnails
    /// Closes the editor. The caller discards the draft.
    let onClose: () -> Void
    @State private var contentHeight: CGFloat = 520
    @State private var chromeHeight: CGFloat = 140

    private var roomName: String {
        model.choreCatalog?.rooms.first { $0.id == editor.roomID }?.name ?? "Room"
    }
    private var style: String { model.roomStyle?.style ?? HouseholdRoomStyle.fallback }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                RoomSheetHeader(title: "Edit \(roomName.lowercased())") {
                    Button("Cancel", action: onClose)
                        .buttonStyle(RoomButtonStyle(kind: .text))
                        .disabled(editor.saving)
                        .accessibilityIdentifier("room-editor-cancel")
                }
                RoomSegmentedPicker("Room editor sections", selection: Binding(get: { editor.section }, set: { section in
                    editor.select(section == .catalog ? editor.selectedID : nil, section: section)
                }), options: RoomEditor.Section.allCases) { section in
                    switch section {
                    case .installed: "In this room (\(Set(editor.installed.map(\.kind)).count))"
                    case .catalog: "Add objects"
                    case .storage: "Storage (\(editor.stored.count))"
                    }
                }
                .accessibilityIdentifier("room-editor-sections")
                .disabled(editor.locked)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        feedback.id("editor-feedback")
                        if let layout = editor.layout, let catalog = editor.catalog {
                            conflicts(layout: layout)
                            switch editor.section {
                            case .installed, .storage:
                                if let selected = editor.selected {
                                    settings(selected, layout: layout, catalog: catalog)
                                } else if editor.section == .installed {
                                    installedList(layout: layout)
                                } else {
                                    storageList(layout: layout, catalog: catalog)
                                }
                            case .catalog:
                                catalogList(layout: layout)
                            }
                        } else {
                            Text(model.roomObjectsFailure ?? "Open a household to edit its room.").foregroundStyle(RoomTheme.muted)
                        }
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: editor.error) { _, error in
                    if error != nil { proxy.scrollTo("editor-feedback", anchor: .top) }
                }
                .onChange(of: model.message) { _, message in
                    if message != nil { proxy.scrollTo("editor-feedback", anchor: .top) }
                }
                .onChange(of: editor.notice) { _, notice in
                    if notice != nil { proxy.scrollTo("editor-feedback", anchor: .top) }
                }
            }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            footer
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .tint(RoomTheme.sage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-editor-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(editor.hasChanges || editor.saving || editor.pendingSave != nil)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + chromeHeight + 90))
    }

    // MARK: - Feedback and footer

    @ViewBuilder private var feedback: some View {
        if !model.canEditRoom {
            RoomFeedback("Editing access unavailable. Your draft is still here; ask an admin to restore access.",
                         identifier: "room-editor-access")
        }
        if let error = editor.error {
            RoomFeedback(error, identifier: "room-editor-error")
        }
        if let message = model.message {
            RoomFeedback(message, identifier: "room-editor-save-error")
        }
        if let invalid = editor.invalidLayout {
            RoomFeedback("\(invalid) Review before applying.")
        }
        if let notice = editor.notice {
            Text(notice).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.leaf)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("room-editor-notice")
        }
        if editor.pendingSave != nil, !editor.saving {
            VStack(alignment: .leading, spacing: 8) {
                Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Button("Retry save") { Task { if await editor.retry() { onClose() } } }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .disabled(model.busy)
            }
        }
        if editor.reviewRequired {
            Button("Review latest room") { Task { await editor.review() } }
                .disabled(model.busy)
                .accessibilityIdentifier("room-editor-review")
        }
    }

    private var footer: some View {
        let count = editor.draft.entries.count
        return VStack(alignment: .leading, spacing: 10) {
            Text(count == 0 ? "No unapplied changes." : "\(count) \(count == 1 ? "object has" : "objects have") unapplied changes.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                .accessibilityIdentifier("room-editor-status")
            Button(editor.saving ? "Saving..." : "Apply for everyone") {
                Task { if await editor.apply() { onClose() } }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(editor.locked || editor.draft.isEmpty || !editor.conflicts.isEmpty || editor.invalidLayout != nil)
            .accessibilityIdentifier("room-editor-apply")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func conflicts(layout: RoomLayout) -> some View {
        ForEach(editor.conflicts, id: \.value.id) { entry in
            let name = RoomEditor.name(entry.value, layout: layout)
            if let latest = editor.saved(entry.value.id) {
                RoomFeedback("\(name) changed while you were editing. Latest: \(latest.name), \(latest.installed ? "in the room" : "in Storage").") {
                    HStack(spacing: 8) {
                        Button("Use latest values") { editor.useLatest(entry.value.id) }
                        Button("Keep my draft") { editor.keepDraft(entry.value.id) }
                    }
                    .buttonStyle(RoomButtonStyle(size: 14))
                }
            } else {
                RoomFeedback("\(name) is unavailable. Discard its draft and choose another object.") {
                    Button("Use latest values") { editor.useLatest(entry.value.id) }
                        .buttonStyle(RoomButtonStyle(size: 14))
                }
            }
        }
    }

    // MARK: - In this room

    private func groups(_ objects: [RoomObjectConfiguration]) -> [(kind: String, items: [RoomObjectConfiguration])] {
        var groups: [(kind: String, items: [RoomObjectConfiguration])] = []
        for object in objects {
            if let index = groups.firstIndex(where: { $0.kind == object.kind }) {
                groups[index].items.append(object)
            } else {
                groups.append((object.kind, [object]))
            }
        }
        return groups
    }

    @ViewBuilder private func installedList(layout: RoomLayout) -> some View {
        grid {
            ForEach(groups(editor.installed), id: \.kind) { group in
                let first = group.items[0]
                let label = group.items.count > 1 ? layout.name(group.kind) : RoomEditor.name(first, layout: layout)
                let inPreview = group.items.contains { editor.saved($0.id)?.installed != true }
                tile(first, label: label, badge: inPreview ? .preview : .placed,
                     details: (group.items.count > 1 ? ["\(group.items.count) objects"] : [])
                        + (group.items.contains { editor.draft.entry($0.id) != nil } ? ["Edited"] : []),
                     accessibility: "Edit \(label)") {
                    editor.select(first.id)
                }
            }
        }
        let storing = editor.draft.entries.filter { !$0.value.installed && $0.value.roomID == editor.roomID }
        if !storing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("In Storage in this draft").font(RoomTheme.body(15).weight(.semibold))
                detail(storing.map { RoomEditor.displayName($0.value, among: editor.roomObjects, layout: layout) }.joined(separator: ", ")
                       + ". Linked care and restock shortcuts will pause; dates and history stay.")
                Button("Open Storage") { editor.select(nil, section: .storage) }
                    .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                    .disabled(editor.locked)
            }
        }
    }

    // MARK: - One object

    @ViewBuilder private func settings(_ object: RoomObjectConfiguration, layout: RoomLayout, catalog: RoomObjectCatalog) -> some View {
        let section = editor.section
        let siblings = editor.roomObjects.filter { $0.kind == object.kind && $0.installed == object.installed }
        let positions = layout.slots.filter { slot in
            slot.roomID == editor.roomID && slot.kinds.contains(object.kind)
                && ((layout.allowed(object.kind, in: editor.roomID) && layout.offered(object.kind, at: slot.id)) || slot.id == object.slotID)
        }
        let kind = catalog.kinds[object.kind]
        let owned = editor.saved(object.id) != nil
        Button { editor.select(nil, section: section) } label: {
            Label(section == .storage ? "All stored objects" : "All room objects", systemImage: "arrow.left")
        }
        .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
        .disabled(editor.locked)
        Text(RoomEditor.name(object, layout: layout)).font(RoomTheme.heading(24)).accessibilityAddTraits(.isHeader)
        if siblings.count > 1 {
            RoomSegmentedPicker("\(layout.name(object.kind)) objects",
                                selection: Binding(get: { object.id }, set: { editor.select($0, section: section) }),
                                options: siblings.map(\.id)) { id in
                siblings.first { $0.id == id }.map { RoomEditor.displayName($0, among: siblings, layout: layout) } ?? id
            }
            .disabled(editor.locked)
        }
        if object.installed && positions.count > 1 {
            RoomPickerField("Move object", selectedLabel: layout.slot(object.slotID)?.name ?? "Designed room position",
                            selection: Binding(get: { object.slotID }, set: { editor.move(object, to: $0) })) {
                ForEach(positions) { slot in
                    let blocked = slot.id != object.slotID
                        && layout.placementReason(editor.preview, roomID: editor.roomID, kind: object.kind, slotID: slot.id, movingID: object.id) != nil
                    Text(slot.name + (slot.id == object.slotID ? " (current)" : blocked ? " (make room first)" : "")).tag(slot.id)
                }
            }
            .disabled(editor.locked)
        }
        if layout.isRetired(object.kind) {
            detail("This object is no longer offered in Add objects. Its current placement, settings and history are kept. It cannot be moved or brought back from Storage. You can still edit it\(object.installed ? " or put it in Storage" : "").")
        } else if !layout.allowed(object.kind, in: editor.roomID) {
            let rooms = (layout.kinds[object.kind]?.placementRooms ?? []).compactMap { id in model.choreCatalog?.rooms.first { $0.id == id }?.name }
            detail("This saved object can stay here. New placements belong in \(rooms.joined(separator: " or ")).")
        } else if !layout.offered(object.kind, at: object.slotID) {
            detail("This saved position can stay. New placements and moves use the offered positions.")
        }
        if object.installed && layout.allowed(object.kind, in: editor.roomID) && positions.contains(where: { $0.id != object.slotID }) {
            Button { editor.addAnother(object) } label: { Label("Add another", systemImage: "plus") }
                .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                .disabled(editor.locked)
        }
        RoomField("Object name", text: Binding(get: { object.name }, set: { name in
            editor.update(object) { $0.name = String(name.prefix(50)) }
        }))
        .disabled(editor.locked)
        if let variants = kind?.variants, variants.count > 1 {
            RoomPickerField("Model", selectedLabel: variants.first { $0.id == object.variant }?.name ?? object.variant,
                            selection: Binding(get: { object.variant }, set: { variant in editor.update(object) { $0.variant = variant } })) {
                ForEach(variants, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(editor.locked)
        }
        RoomPickerField("Finish", selectedLabel: catalog.finishes[object.finish] ?? object.finish,
                        selection: Binding(get: { object.finish }, set: { finish in editor.update(object) { $0.finish = finish } })) {
            ForEach(layout.finishOrder, id: \.self) { Text(catalog.finishes[$0] ?? $0).tag($0) }
        }
        .disabled(editor.locked)
        supplies(object, layout: layout)
        if object.installed {
            if layout.slot(object.slotID)?.removable == true {
                Button { editor.putInStorage(object) } label: {
                    Label(owned ? "Put in storage" : "Discard trial object", systemImage: owned ? "archivebox" : "xmark")
                }
                .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                .disabled(editor.locked)
                .accessibilityIdentifier("room-editor-store")
            } else {
                detail("This fitted object stays in the room. Its name, finish and supply shortcuts can still be changed.")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                detail((editor.saved(object.id)?.installed == true
                        ? "In Storage in your private draft. Apply for everyone to share this change."
                        : "In Storage. Restock shortcuts and linked care are paused.") + " Dates, names, settings and history are kept.")
                if layout.allowed(object.kind, in: editor.roomID) {
                    Button { editor.bringBack(object) } label: { Label("Bring back", systemImage: "arrow.uturn.backward") }
                        .disabled(editor.locked)
                } else if let reason = layout.placementReason(editor.preview, roomID: editor.roomID, kind: object.kind,
                                                              slotID: object.slotID, movingID: object.id) {
                    detail(reason)
                }
            }
        }
    }

    @ViewBuilder private func supplies(_ object: RoomObjectConfiguration, layout: RoomLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(RoomTheme.border).frame(height: 1).padding(.bottom, 4)
            Text("Supply shortcuts").font(RoomTheme.body(17).weight(.semibold)).accessibilityAddTraits(.isHeader)
            detail("These names and quantities become shortcuts to the shared shopping list. No stock is tracked, and saving this room does not order or add anything.")
            ForEach(Array(object.supplies.enumerated()), id: \.element.id) { index, supply in
                HStack(alignment: .bottom, spacing: 8) {
                    RoomField("Supply name \(index + 1)", text: Binding(get: { supply.name }, set: { name in
                        editor.update(object) { value in
                            value.supplies = value.supplies.map { $0.id == supply.id ? RoomObject.Supply(id: $0.id, name: String(name.prefix(50)), quantity: $0.quantity) : $0 }
                        }
                    }))
                    RoomField("Supply quantity \(index + 1)", text: Binding(get: { supply.quantity }, set: { quantity in
                        editor.update(object) { value in
                            value.supplies = value.supplies.map { $0.id == supply.id ? RoomObject.Supply(id: $0.id, name: $0.name, quantity: String(quantity.prefix(40))) : $0 }
                        }
                    }))
                    .frame(maxWidth: 120)
                    Button { editor.update(object) { $0.supplies.removeAll { $0.id == supply.id } } } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RoomTheme.error)
                    .accessibilityLabel("Remove supply \(index + 1)")
                }
                .disabled(editor.locked)
            }
            if object.supplies.isEmpty { detail("No supply shortcuts for this object.") }
            HStack(spacing: 8) {
                Button { editor.addSupply(to: object) } label: { Label("Add supply shortcut", systemImage: "plus") }
                    .buttonStyle(RoomButtonStyle(size: 14))
                    .disabled(editor.locked || object.supplies.count >= layout.supplyLimit)
                Button { editor.update(object) { $0.supplies = layout.suggestedSupplies($0) } } label: {
                    Label("Use suggested supplies", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                .disabled(editor.locked || object.supplies == layout.suggestedSupplies(object))
            }
            if object.supplies.count >= layout.supplyLimit {
                detail("An object can have up to \(layout.supplyLimit) supply shortcuts.")
            }
        }
    }

    // MARK: - Storage

    @ViewBuilder private func storageList(layout: RoomLayout, catalog: RoomObjectCatalog) -> some View {
        detail("Stored objects keep their history. Supplies and linked chores resume when you bring them back.")
        if editor.stored.isEmpty {
            Text("Storage is empty. Put a removable object in storage to keep it for later.").foregroundStyle(RoomTheme.muted)
                .accessibilityIdentifier("room-editor-storage-empty")
        }
        ForEach(groups(editor.stored), id: \.kind) { group in
            VStack(alignment: .leading, spacing: 10) {
                Text("\(layout.name(group.kind)) (\(group.items.count))").font(RoomTheme.body(15).weight(.semibold))
                grid {
                    ForEach(group.items) { object in
                        let label = RoomEditor.displayName(object, among: group.items, layout: layout)
                        VStack(alignment: .leading, spacing: 8) {
                            tile(object, label: label, badge: nil,
                                 details: ["\(catalog.kinds[object.kind]?.variants.first { $0.id == object.variant }?.name ?? object.variant); \(catalog.finishes[object.finish] ?? object.finish)",
                                           editor.saved(object.id)?.installed == true ? "In Storage in this draft" : "In Storage"],
                                 accessibility: "Edit stored \(label)") {
                                editor.select(object.id, section: .storage)
                            }
                            if layout.allowed(object.kind, in: editor.roomID) {
                                Button { editor.bringBack(object) } label: { Label("Bring back", systemImage: "arrow.uturn.backward") }
                                    .buttonStyle(RoomButtonStyle(size: 14))
                                    .disabled(editor.locked)
                                    .accessibilityLabel("Bring back \(label)")
                            } else if let reason = layout.placementReason(editor.preview, roomID: editor.roomID, kind: object.kind,
                                                                          slotID: object.slotID, movingID: object.id) {
                                detail(reason)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Add objects

    @ViewBuilder private func catalogList(layout: RoomLayout) -> some View {
        let saved = editor.current.map(RoomObjectConfiguration.init)
        let preview = editor.preview
        let query = ShoppingRestock.normalized(editor.search)
        let matching = layout.kindOrder.filter { kind in
            guard let definition = layout.kinds[kind], layout.allowed(kind, in: editor.roomID) else { return false }
            let description = editor.catalog?.kinds[kind]?.description ?? ""
            return layout.slots.contains {
                $0.roomID == editor.roomID && $0.kinds.contains(kind) && layout.offered(kind, at: $0.id)
                    && (editor.surface == nil || $0.surface == editor.surface)
            }
                && (editor.category == nil || definition.category == editor.category)
                && (query.isEmpty || ShoppingRestock.normalized("\(definition.name) \(description)").contains(query))
        }
        let availability = Dictionary(uniqueKeysWithValues: matching.map { kind in
            (kind, layout.availability(kind: kind, roomID: editor.roomID, preview: preview, saved: saved,
                                       surface: editor.surface, selectedID: editor.selectedID))
        })
        let shown = matching.filter { kind in
            switch editor.availabilityFilter {
            case .all: true
            case .available: (availability[kind]?.free ?? 0) > 0
            case .placed: availability[kind]?.status == .placed
            case .preview: availability[kind]?.status == .preview
            }
        }
        RoomField("Find an object", text: Binding(get: { editor.search }, set: { editor.search = String($0.prefix(80)) }))
            .disabled(editor.locked)
        RoomPickerField("Object category", selectedLabel: layout.categories.first { $0.id == editor.category }?.name ?? "All objects",
                        selection: Binding(get: { editor.category ?? "" }, set: { editor.category = $0.isEmpty ? nil : $0 })) {
            Text("All objects").tag("")
            ForEach(layout.categories, id: \.id) { Text($0.name).tag($0.id) }
        }
        .disabled(editor.locked)
        chips(label: "Filter object zones",
              options: [(nil as String?, "All zones")] + layout.zoneUsage(preview, roomID: editor.roomID).map { ($0.surface, $0.label) },
              selected: editor.surface) { editor.surface = $0 }
        let previewCount = availability.values.filter { $0.status == .preview }.count
        let filters: [(RoomEditor.AvailabilityFilter, String)] = [
            (.all, "All objects \(matching.count)"),
            (.available, "Available \(availability.values.filter { $0.free > 0 }.count)"),
            (.placed, "Placed \(availability.values.filter { $0.status == .placed }.count)"),
        ] + (previewCount > 0 || editor.availabilityFilter == .preview ? [(.preview, "In preview \(previewCount)")] : [])
        chips(label: "Filter object availability", options: filters, selected: editor.availabilityFilter) { editor.availabilityFilter = $0 }
        if shown.isEmpty {
            Text("No matching objects. Try another name or filter.").foregroundStyle(RoomTheme.muted)
        }
        let zones = catalogZones(shown, availability: availability, layout: layout)
        ForEach(zones, id: \.zone) { zone in
            VStack(alignment: .leading, spacing: 10) {
                Text(zone.zone == "room" ? "Room essentials" : layout.zones.first { $0.id == zone.zone }?.label ?? zone.zone)
                    .font(RoomTheme.body(15).weight(.semibold)).accessibilityAddTraits(.isHeader)
                grid {
                    ForEach(zone.kinds, id: \.self) { kind in
                        if let status = availability[kind] { catalogCard(kind, status: status, layout: layout) }
                    }
                }
            }
        }
    }

    private func catalogZones(_ kinds: [String], availability: [String: RoomLayout.Availability],
                              layout: RoomLayout) -> [(zone: String, kinds: [String])] {
        var zones: [(zone: String, kinds: [String])] = []
        for kind in kinds {
            guard let status = availability[kind] else { continue }
            let slot = editor.surface != nil ? status.position : status.instance.flatMap { layout.slot($0.slotID) } ?? status.position
            let zone = editor.surface ?? slot?.surface ?? "room"
            if let index = zones.firstIndex(where: { $0.zone == zone }) {
                zones[index].kinds.append(kind)
            } else {
                zones.append((zone, [kind]))
            }
        }
        return zones
    }

    @ViewBuilder private func catalogCard(_ kind: String, status: RoomLayout.Availability, layout: RoomLayout) -> some View {
        let name = layout.name(kind)
        let focus = status.stored == nil ? status.instance : nil
        let slot = focus.flatMap { layout.slot($0.slotID) } ?? status.position
        let look: RoomObjectConfiguration? = focus ?? status.stored.map { stored in
            var object = stored
            if let slot { object.slotID = slot.id }
            return object
        } ?? slot.flatMap { layout.newObject(kind: kind, slotID: $0.id, id: "preview") }
        let note = focus.map { "\(name) is already placed at \(layout.slot($0.slotID)?.name ?? "its position"). Preview opens its settings." }
            ?? status.reason ?? slot.map { "\(name) can be previewed at \($0.name)." } ?? ""
        if let look {
            tile(look, label: name, badge: status.status, details: [status.label], accessibility: "Preview \(name) in the room",
                 hint: note) {
                if let focus {
                    editor.select(focus.id)
                } else if let position = status.position {
                    editor.previewPlacement(kind: kind, slotID: position.id, storedID: status.stored?.id)
                }
            }
            .accessibilityIdentifier("room-editor-catalog-\(kind)")
        }
    }

    // MARK: - Pieces

    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // The web grid's `repeat(auto-fill, minmax(8rem, 1fr))` on narrow screens.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)], spacing: 12, content: content)
    }

    private func tile(_ object: RoomObjectConfiguration, label: String, badge: RoomLayout.Availability.Status?, details: [String],
                      accessibility: String, hint: String? = nil, action: @escaping () -> Void) -> some View {
        let look = RoomThumbnails.Look(object, state: editor.saved(object.id)?.state)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RadialGradient(colors: [.white, Color(white: 0.992), Color(red: 0.965, green: 0.969, blue: 0.969)],
                                   center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: 140)
                    switch thumbnails.picture(look, roomStyle: style) {
                    case .image(let image): Image(uiImage: image).resizable().scaledToFit()
                    case .loading: ProgressView().tint(RoomTheme.muted)
                    case .unavailable:
                        Text("3D is unavailable.").font(RoomTheme.body(12)).foregroundStyle(RoomTheme.error)
                            .multilineTextAlignment(.center).padding(10)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                Rectangle().fill(RoomTheme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(label).font(RoomTheme.body(14).weight(.semibold)).foregroundStyle(RoomTheme.leaf)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge { availabilityBadge(badge) }
                    }
                    ForEach(details, id: \.self) { detail($0) }
                }
                .multilineTextAlignment(.leading)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoomTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RoomTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(editor.locked)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityHint(hint ?? "")
        .onAppear { thumbnails.load(look, roomStyle: style) }
    }

    /// The web's `AvailabilityBadge` icons.
    private func availabilityBadge(_ status: RoomLayout.Availability.Status) -> some View {
        let (icon, label, fill, ink): (String, String, Color, Color) = switch status {
        case .available: ("plus", "Available", RoomTheme.leafSoft, RoomTheme.leaf)
        case .placed: ("checkmark", "Placed", RoomTheme.sage, RoomTheme.primaryInk)
        case .preview: ("pencil", "In preview", RoomTheme.sunflowerSoft, RoomTheme.ink)
        case .occupied: ("exclamationmark.triangle", "Make room first", RoomTheme.errorSoft, RoomTheme.error)
        }
        return Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 20, height: 20)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(label)
    }

    private func chips<Value: Hashable>(label: String, options: [(Value, String)], selected: Value,
                                        choose: @escaping (Value) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { value, title in
                    Button { choose(value) } label: {
                        Text(title)
                            .font(RoomTheme.body(14).weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(value == selected ? RoomTheme.leafSoft : RoomTheme.surface,
                                        in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(value == selected ? .isSelected : [])
                }
            }
        }
        .disabled(editor.locked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The placement preview over the live room, as the web's compact editor panel: place the object, choose a swap
/// or another position, or discard the preview.
struct RoomPlacementBar: View {
    @Bindable var model: AccountModel
    @Bindable var editor: RoomEditor

    var body: some View {
        if let placement = editor.placement, let layout = editor.layout {
            let name = RoomEditor.name(placement.candidate, layout: layout)
            let issue = editor.error ?? editor.placementIssue
            let swapping = placement.swapIDs != nil
            VStack(alignment: .leading, spacing: 10) {
                Text("Try \(name)").font(RoomTheme.heading(20)).accessibilityAddTraits(.isHeader)
                Text(layout.slot(placement.candidate.slotID)?.name ?? "Designed room position")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                if let issue { RoomFeedback(issue, identifier: "placement-error") }
                if let message = model.message { RoomFeedback(message) }
                if let reason = placement.readOnlyReason, !swapping {
                    Text(reason).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("placement-reason")
                }
                if swapping { swap(placement, name: name, layout: layout) }
                HStack(spacing: 8) {
                    Button {
                        editor.acceptPlacement()
                    } label: {
                        Label((placement.swapIDs?.isEmpty ?? true) ? "Place object" : "Stage swap", systemImage: "checkmark")
                    }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .disabled(editor.locked || (placement.readOnlyReason != nil && !swapping)
                              || editor.placementIssue != nil || editor.proposedError != nil)
                    .accessibilityIdentifier("place-object")
                    Button { editor.discardPlacement() } label: { Label("Discard preview", systemImage: "xmark") }
                        .disabled(editor.saving)
                        .accessibilityIdentifier("discard-placement")
                }
                if placement.readOnlyReason != nil, !swapping, !editor.swapPositions.isEmpty {
                    Button("Choose a swap or another position") { editor.startSwap() }
                        .buttonStyle(RoomButtonStyle(kind: .text, size: 14))
                        .disabled(editor.locked || !editor.conflicts.isEmpty)
                        .accessibilityIdentifier("start-swap")
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoomTheme.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RoomTheme.border))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .font(RoomTheme.body())
            .foregroundStyle(RoomTheme.ink)
            .buttonStyle(RoomButtonStyle())
            .tint(RoomTheme.sage)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("placement-bar")
        }
    }

    @ViewBuilder private func swap(_ placement: RoomEditor.Placement, name: String, layout: RoomLayout) -> some View {
        let objects = editor.swapObjects
        let chosen = placement.swapIDs ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Make room for \(name)").font(RoomTheme.body(15).weight(.semibold))
                RoomPickerField("Placement position", selectedLabel: layout.slot(placement.candidate.slotID)?.name ?? "",
                                selection: Binding(get: { placement.candidate.slotID }, set: { editor.choosePosition($0) })) {
                    ForEach(editor.swapPositions) { Text($0.name).tag($0.id) }
                }
                .disabled(editor.locked)
                Text("Choose the objects to put in Storage. Linked care and restock shortcuts pause; names, settings, dates and history stay. An unsaved trial is discarded instead.")
                    .font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let required = editor.requiredOccupant {
                    RoomFeedback("\(RoomEditor.name(required, layout: layout)) is a required fixture and cannot be put in Storage.")
                }
                ForEach(objects) { object in
                    let owned = editor.saved(object.id) != nil
                    let label = RoomEditor.displayName(object, among: editor.roomObjects, layout: layout)
                    RoomSwitch("\(owned ? "Put" : "Discard") \(label)\(owned ? " in Storage" : " unsaved trial")",
                               isOn: Binding(get: { chosen.contains(object.id) }, set: { _ in editor.toggleSwap(object.id) }))
                        .disabled(editor.locked)
                }
                if objects.isEmpty {
                    Text("There are no removable objects in this zone. Try another compatible position.")
                        .font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
                }
                if !chosen.isEmpty {
                    Text("Chosen: \(chosen.compactMap { id in objects.first { $0.id == id } }.map { RoomEditor.name($0, layout: layout) }.joined(separator: ", ")). Nothing is staged until you confirm.")
                        .font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
                }
            }
        }
        .frame(maxHeight: 260)
    }
}
