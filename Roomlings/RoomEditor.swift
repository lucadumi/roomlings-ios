import Foundation
import RoomlingsCore

/// The room editor's private draft for one room, matching the web's `RoomEditor` (`src/RoomComponents.tsx`).
/// It lives with the room screen so a placement can be previewed in the room between visits to the sheet.
@MainActor @Observable
final class RoomEditor {
    enum Section: String, CaseIterable, Hashable {
        case installed, catalog, storage
    }

    enum AvailabilityFilter: String, Hashable {
        case all, available, placed, preview
    }

    /// An object tried in the room before it joins the draft. A read-only preview shows a blocked position
    /// until a swap or another position is chosen.
    struct Placement: Equatable {
        var candidate: RoomObjectConfiguration
        let base: RoomObject?
        let section: Section
        let selectedID: String?
        let readOnlyReason: String?
        /// Objects chosen for Storage to make room, in the order chosen. Nil until a swap is started.
        var swapIDs: [String]?
    }

    struct Save: Equatable {
        let version: Int64
        let mutationID = UUID()
        let patch: RoomObjectsPatch
    }

    let householdID: UUID
    let roomID: String
    private let accounts: AccountModel
    private(set) var draft = RoomEditorDraft()
    private(set) var placement: Placement?
    var section = Section.installed
    private(set) var selectedID: String?
    var surface: String?
    var category: String?
    var search = ""
    var availabilityFilter = AvailabilityFilter.all
    var error: String?
    var notice: String?
    private(set) var pendingSave: Save?
    private(set) var reviewRequired = false
    private(set) var saving = false

    init(accounts: AccountModel, householdID: UUID, roomID: String) {
        self.accounts = accounts
        self.householdID = householdID
        self.roomID = roomID
    }

    // MARK: - The room as drafted

    var catalog: RoomObjectCatalog? { accounts.roomObjectCatalog }
    var layout: RoomLayout? { catalog?.layout }
    var current: [RoomObject] { accounts.roomObjects }
    var preview: [RoomObjectConfiguration] { draft.preview(current) }
    var locked: Bool { accounts.busy || saving || pendingSave != nil || reviewRequired || !accounts.canEditRoom }
    var hasChanges: Bool { !draft.isEmpty || placement != nil }
    var roomObjects: [RoomObjectConfiguration] { preview.filter { $0.roomID == roomID } }
    var installed: [RoomObjectConfiguration] { roomObjects.filter(\.installed) }
    var stored: [RoomObjectConfiguration] {
        roomObjects.filter { object in !object.installed && current.contains { $0.id == object.id } }
    }
    var selected: RoomObjectConfiguration? { roomObjects.first { $0.id == selectedID } }
    var conflicts: [RoomEditorDraft.Entry] { draft.conflicts(current) }
    var inspection: Bool { placement?.readOnlyReason != nil }

    func saved(_ id: String) -> RoomObject? { current.first { $0.id == id } }

    var invalidLayout: String? {
        guard let layout else { return nil }
        let preview = preview
        return layout.validate(preview) ?? draft.placementReason(current, preview: preview, layout: layout)
    }

    /// What blocks the placement preview, as the web's `trialIssue`.
    var placementIssue: String? {
        guard let placement, let layout else { return nil }
        let latest = saved(placement.candidate.id)
        if placement.base.map({ latest?.version != $0.version }) ?? (latest != nil) {
            return "This object changed while you were previewing it. Discard this preview and review its latest settings."
        }
        if let changed = placement.swapIDs?.compactMap({ id in preview.first { $0.id == id } })
            .first(where: { object in !object.installed || object.roomID != roomID }) {
            return "\(Self.name(changed, layout: layout)) changed. Choose it again to review the latest Storage tradeoff."
        }
        if !conflicts.isEmpty { return "The room changed. Discard this preview and review your draft before placing the object." }
        if !inspection, let reason = layout.placementReason(preview, roomID: roomID, kind: placement.candidate.kind,
                                                             slotID: placement.candidate.slotID, movingID: placement.candidate.id) {
            return "This position is now blocked. \(reason)"
        }
        return inspection ? nil : proposedError
    }

    /// Why the placement cannot join the draft with the current swap choices.
    var proposedError: String? {
        guard let placement, let layout else { return nil }
        do {
            _ = try draft.placing(placement.candidate, storing: placement.swapIDs ?? [], current: current, layout: layout)
            return nil
        } catch let error as RoomEditorError {
            return error.message
        } catch {
            return "Review this placement before adding it to your draft."
        }
    }

    /// The objects the room shows: the draft, and a previewed placement with its swap choices stored.
    var visible: [RoomObjectConfiguration] {
        guard let placement, inspection || placementIssue == nil else { return preview }
        let shown = RoomEditorDraft.inspection(preview, candidate: placement.candidate, storing: placement.swapIDs ?? [])
        return shown.count <= (layout?.objectLimit ?? 0) ? shown : preview
    }

    /// The draft as the bundled room reads it. Names and supplies are not drawn, so an unfinished name never
    /// stops the preview.
    var roomComponents: JSONValue {
        .array(visible.map { object in
            let base = saved(object.id)
            let name = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .object([
                "id": .string(object.id), "kind": .string(object.kind), "roomId": .string(object.roomID),
                "slotId": .string(object.slotID),
                "name": .string(name.isEmpty || name.count > 50 ? layout?.name(object.kind) ?? object.kind : name),
                "variant": .string(object.variant), "finish": .string(object.finish), "supplies": .array([]),
                "installed": .bool(object.installed), "version": .integer(base?.version ?? 0),
                "state": base?.state.map(JSONValue.string) ?? .null,
                "stateChangedAt": base?.stateChangedAt.map(JSONValue.string) ?? .null,
                "stateChangedBy": base?.stateChangedBy.map { .string($0.uuidString.lowercased()) } ?? .null,
            ])
        })
    }

    // MARK: - Editing

    func select(_ id: String?, section next: Section = .installed) {
        if placement != nil { return }
        selectedID = id
        section = next
        error = nil
    }

    func update(_ object: RoomObjectConfiguration, _ change: (inout RoomObjectConfiguration) -> Void) {
        guard !locked else { return }
        var value = draft.entry(object.id)?.value ?? object
        change(&value)
        draft = draft.staging(value, current: current)
        error = nil
        notice = nil
    }

    func move(_ object: RoomObjectConfiguration, to slotID: String) {
        guard !locked, let layout, slotID != object.slotID else { return }
        if let reason = layout.placementReason(preview, roomID: roomID, kind: object.kind, slotID: slotID, movingID: object.id) {
            var candidate = object
            candidate.slotID = slotID
            begin(candidate, reason: reason)
        } else {
            update(object) { $0.slotID = slotID }
        }
    }

    func addSupply(to object: RoomObjectConfiguration) {
        update(object) { $0.supplies.append(RoomObject.Supply(id: UUID().uuidString.lowercased(), name: "", quantity: "1")) }
    }

    func putInStorage(_ object: RoomObjectConfiguration) {
        guard !locked, let layout else { return }
        do {
            draft = try draft.storing(object, current: current, layout: layout)
            let name = Self.name(object, layout: layout)
            let owned = saved(object.id) != nil
            selectedID = nil
            section = owned ? .storage : .installed
            error = nil
            notice = owned
                ? "\(name) is in Storage in your private draft. Apply for everyone to pause its linked care and restock shortcuts. Dates, settings and history are kept."
                : "\(name) was an unsaved trial and has been discarded."
        } catch let failure as RoomEditorError {
            error = failure.message
        } catch {
            self.error = "This object could not be put in Storage."
        }
    }

    // MARK: - Placement preview

    func previewPlacement(kind: String, slotID: String, storedID: String? = nil) {
        guard !locked, let layout else { return }
        guard layout.allowed(kind, in: roomID) else {
            error = layout.placementReason(preview, roomID: roomID, kind: kind, slotID: slotID) ?? "Choose an offered placement."
            return
        }
        let owned = storedID.map { id in stored.first { $0.id == id && $0.kind == kind } }
            ?? stored.first { $0.kind == kind && $0.slotID == slotID } ?? stored.first { $0.kind == kind }
        if storedID != nil, owned == nil {
            error = "That stored object changed. Review Storage before bringing it back."
            return
        }
        let candidate: RoomObjectConfiguration?
        if var owned {
            owned.slotID = slotID
            owned.installed = true
            candidate = owned
        } else {
            candidate = layout.newObject(kind: kind, slotID: slotID, id: UUID().uuidString.lowercased())
        }
        guard let candidate else {
            error = "This object could not be previewed. Your draft is unchanged."
            return
        }
        let reason = owned == nil && preview.count >= layout.objectLimit
            ? "This home has reached its saved-object limit. Bring back an owned object, or discard an unused draft-only trial."
            : nil
        begin(candidate, reason: reason)
    }

    func bringBack(_ object: RoomObjectConfiguration) {
        guard !locked, let layout else { return }
        let available = layout.availability(kind: object.kind, roomID: roomID, preview: preview,
                                            saved: current.map(RoomObjectConfiguration.init), storedID: object.id)
        guard let position = layout.preferredSlot(kind: object.kind, among: available.available, objects: preview, objectID: object.id)
            ?? layout.preferredSlot(kind: object.kind, among: available.positions, objects: preview, objectID: object.id) else {
            error = available.reason ?? "No compatible position is offered for this stored object."
            return
        }
        previewPlacement(kind: object.kind, slotID: position.id, storedID: object.id)
    }

    func addAnother(_ object: RoomObjectConfiguration) {
        guard !locked, let layout else { return }
        let available = layout.availability(kind: object.kind, roomID: roomID, preview: preview,
                                            saved: current.map(RoomObjectConfiguration.init))
        guard let position = layout.preferredSlot(kind: object.kind, among: available.available, objects: preview)
            ?? layout.preferredSlot(kind: object.kind, among: available.positions.filter { $0.id != object.slotID }, objects: preview) else {
            error = "There are no offered positions for another object."
            return
        }
        previewPlacement(kind: object.kind, slotID: position.id)
    }

    private func begin(_ candidate: RoomObjectConfiguration, reason: String?) {
        guard let layout else { return }
        placement = Placement(
            candidate: candidate, base: saved(candidate.id), section: section, selectedID: selectedID,
            readOnlyReason: reason ?? layout.placementReason(preview, roomID: roomID, kind: candidate.kind,
                                                              slotID: candidate.slotID, movingID: candidate.id),
            swapIDs: nil
        )
        selectedID = candidate.id
        error = nil
        notice = nil
    }

    /// Positions offered for a swap, as the web's placement position menu.
    var swapPositions: [RoomLayout.Slot] {
        guard let placement, let layout else { return [] }
        return layout.availability(kind: placement.candidate.kind, roomID: roomID, preview: preview,
                                   saved: current.map(RoomObjectConfiguration.init), movingID: placement.candidate.id).positions
    }

    /// Removable objects in the target position or its zone that could go to Storage.
    var swapObjects: [RoomObjectConfiguration] {
        guard let placement, let layout else { return [] }
        let surface = layout.slot(placement.candidate.slotID)?.surface
        var objects = installed.filter { object in
            object.id != placement.candidate.id && layout.slot(object.slotID)?.removable == true
                && (object.slotID == placement.candidate.slotID || (surface != nil && layout.slot(object.slotID)?.surface == surface))
        }
        for id in placement.swapIDs ?? [] where !objects.contains(where: { $0.id == id }) {
            if let chosen = preview.first(where: { $0.id == id }) { objects.append(chosen) }
        }
        return objects
    }

    /// A fitted object in the target position, which can never be put away.
    var requiredOccupant: RoomObjectConfiguration? {
        guard let placement, let layout else { return nil }
        return installed.first {
            $0.id != placement.candidate.id && $0.slotID == placement.candidate.slotID && layout.slot($0.slotID)?.removable != true
        }
    }

    func startSwap() {
        guard var next = placement, !locked else { return }
        next.swapIDs = []
        placement = next
        error = nil
    }

    func choosePosition(_ slotID: String) {
        guard var next = placement, !locked else { return }
        guard swapPositions.contains(where: { $0.id == slotID }) else {
            error = "Choose a compatible position for this object."
            return
        }
        next.candidate.slotID = slotID
        next.swapIDs = []
        placement = next
        error = nil
    }

    func toggleSwap(_ id: String) {
        guard var next = placement, !locked else { return }
        var chosen = next.swapIDs ?? []
        if let index = chosen.firstIndex(of: id) { chosen.remove(at: index) } else { chosen.append(id) }
        next.swapIDs = chosen
        placement = next
        error = nil
    }

    func discardPlacement() {
        guard let placement, !saving else { return }
        self.placement = nil
        selectedID = placement.selectedID
        section = placement.section
        error = nil
        notice = placement.readOnlyReason == nil ? "The placement preview was discarded. Your other draft changes are kept." : nil
    }

    func acceptPlacement() {
        guard let placement, !locked, let layout else { return }
        if placement.readOnlyReason != nil && placement.swapIDs == nil {
            error = "This is a read-only preview. Choose and confirm a swap before placing it."
            return
        }
        if let issue = placementIssue ?? proposedError {
            error = issue
            return
        }
        do {
            let swapIDs = placement.swapIDs ?? []
            draft = try draft.placing(placement.candidate, storing: swapIDs, current: current, layout: layout)
            let chosen = swapIDs.compactMap { id in roomObjects.first { $0.id == id } }
            let storedNames = chosen.filter { saved($0.id) != nil }.map { Self.name($0, layout: layout) }
            let discarded = chosen.filter { saved($0.id) == nil }.map { Self.name($0, layout: layout) }
            self.placement = nil
            selectedID = nil
            section = .installed
            error = nil
            notice = "\(Self.name(placement.candidate, layout: layout)) is kept in your private draft."
                + (storedNames.isEmpty ? "" : " In Storage: \(storedNames.joined(separator: ", ")).")
                + (discarded.isEmpty ? "" : " Discarded unsaved trials: \(discarded.joined(separator: ", ")).")
                + " Apply for everyone to share it. Supplies and chores are not added automatically."
        } catch let failure as RoomEditorError {
            error = failure.message
        } catch {
            self.error = "Review this placement before adding it to the draft."
        }
    }

    // MARK: - Roommate changes

    func useLatest(_ id: String) {
        draft = draft.without(id)
        if selectedID == id { section = saved(id)?.installed == false ? .storage : .installed }
        error = nil
        notice = "The latest object settings are now in your preview."
    }

    func keepDraft(_ id: String) {
        guard let latest = saved(id) else { return }
        draft = draft.keeping(id, latest: latest)
        error = nil
        notice = "Draft kept and roommate changes included. Review before applying."
    }

    // MARK: - Apply for everyone

    func apply() async -> Bool {
        guard !locked, let layout else { return false }
        if placement != nil { error = "Place or discard the previewed object before applying your draft."; return false }
        if !conflicts.isEmpty { error = "Review the changed objects before applying your draft."; return false }
        if let invalidLayout { error = invalidLayout; return false }
        guard let household = accounts.state?.session?.household, household.id == householdID else {
            error = "Your selected household changed. Your draft is still here; reopen this household to apply it."
            return false
        }
        let patch: RoomObjectsPatch
        do {
            patch = try draft.patch(roomID: roomID, layout: layout)
        } catch let failure as RoomEditorError {
            error = failure.message
            return false
        } catch {
            self.error = "Review your draft before applying it."
            return false
        }
        error = nil
        let save = Save(version: household.version, patch: patch)
        pendingSave = save
        return await send(save)
    }

    /// Sends the unconfirmed save again with the same identifier, so it can never apply twice.
    func retry() async -> Bool {
        guard let pendingSave, !saving, !accounts.busy else { return false }
        return await send(pendingSave)
    }

    private func send(_ save: Save) async -> Bool {
        saving = true
        defer { saving = false }
        let applied = await accounts.applyRoomDraft(save.patch, householdID: householdID, version: save.version,
                                                    mutationID: save.mutationID)
        if applied {
            pendingSave = nil
            draft = RoomEditorDraft()
            return true
        }
        switch accounts.roomLayoutSaveFailure {
        case .retrySameChange: break
        case .refreshRequired: pendingSave = nil; reviewRequired = true
        case .none: pendingSave = nil
        }
        return false
    }

    /// Loads the latest room after a conflict. The draft stays; changed objects then ask to be reviewed.
    func review() async {
        guard await accounts.refresh() else { return }
        pendingSave = nil
        reviewRequired = false
        notice = "The latest room is loaded. Review changed objects before applying."
    }

    // MARK: - Names

    static func name(_ object: RoomObjectConfiguration, layout: RoomLayout) -> String {
        let name = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? layout.name(object.kind) : name
    }

    /// The web's `componentDisplayName`: objects that share a name in a room are numbered.
    static func displayName(_ object: RoomObjectConfiguration, among objects: [RoomObjectConfiguration], layout: RoomLayout) -> String {
        let name = name(object, layout: layout)
        let matches = objects.filter { $0.roomID == object.roomID && Self.name($0, layout: layout) == name }
        guard matches.contains(where: { $0.id != object.id }) else { return name }
        let index = matches.firstIndex { $0.id == object.id }.map { $0 + 1 } ?? matches.count + 1
        return "\(name) \(index)"
    }
}
