import RoomlingsCore
import SwiftUI

struct ShoppingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountModel
    @State private var section = Section.list
    @State private var page = Page.board
    @State private var name = ""
    @State private var quantity = "1"
    @State private var notes = ""
    @State private var receipt = ReceiptFormValues()
    @State private var formError: String?
    @State private var pending: Save?
    @State private var reviewRequired = false
    @State private var contentHeight: CGFloat = 480
    @State private var headerHeight: CGFloat = 64

    private enum Section: String, CaseIterable {
        case list = "List", basket = "Basket"
    }

    private enum Page {
        case board, form(ShoppingItem?), remove(ShoppingItem), release(ShoppingItem)
        case receipt

        var id: String {
            switch self {
            case .board: "board"
            case .form(let item): "form-\(item?.id.uuidString ?? "new")"
            case .remove(let item): "remove-\(item.id)"
            case .release(let item): "release-\(item.id)"
            case .receipt: "receipt-basket"
            }
        }

        var title: String {
            switch self {
            case .board: "Shared shopping list"
            case .form(let item): item == nil ? "Add to the shared list." : "Edit a shopping item."
            case .remove: "Remove this shopping item?"
            case .release: "Release this shopping claim?"
            case .receipt: "Record your basket."
            }
        }

    }

    private enum Change {
        case add(ShoppingDraft), edit(ShoppingItem, ShoppingDraft), remove(ShoppingItem)
        case claim(ShoppingItem, Bool), pick(ShoppingItem, Bool)
        case checkout(ExpenseDraft, UUID, [ShoppingSelection])

        /// A checkout reports its outcome through the ledger projection, not the list.
        var isLedger: Bool {
            if case .checkout = self { return true }
            return false
        }
    }

    private struct Save {
        let householdID: UUID
        let version: Int64
        let mutationID = UUID()
        let change: Change
    }

    private var changesBlocked: Bool { model.busy || pending != nil || reviewRequired }
    private var dismissalBlocked: Bool { model.busy || pending != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(page.title).font(RoomTheme.heading()).accessibilityAddTraits(.isHeader)
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
                        feedback.id("shopping-feedback")
                        if let shopping = model.shopping, let session = model.state?.session, model.canUseAccount {
                            switch page {
                            case .board: board(shopping, memberID: session.memberID)
                            case .form(let item): form(item, shopping: shopping, memberID: session.memberID)
                            case .remove(let item): confirmation(item, releasing: false, shopping: shopping, memberID: session.memberID)
                            case .release(let item): confirmation(item, releasing: true, shopping: shopping, memberID: session.memberID)
                            case .receipt: receiptForm(shopping: shopping, memberID: session.memberID)
                            }
                        } else {
                            RoomFeedback(model.shoppingFailure ?? "Open a household to use its shopping list.",
                                         identifier: "shopping-unavailable")
                        }
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .id(page.id)
                .scrollDismissesKeyboard(.interactively)
                .disabled(model.busy)
                .onChange(of: model.message) { _, message in
                    if message != nil { proxy.scrollTo("shopping-feedback", anchor: .top) }
                }
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { proxy.scrollTo("shopping-feedback", anchor: .top) }
                }
                .onChange(of: formError) { _, error in
                    if error != nil { proxy.scrollTo("shopping-feedback", anchor: .top) }
                }
            }
            .modifier(RoomSheetLoading(model: model, label: "Loading shopping..."))
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .tint(RoomTheme.sage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopping-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(dismissalBlocked)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
    }

    @ViewBuilder private var feedback: some View {
        if model.busy {
            HStack {
                RoomBrandMark()
                Text(pending == nil ? "Refreshing shopping..." : "Saving the list...")
            }
            .accessibilityIdentifier("shopping-progress")
        }
        if let message = model.message ?? formError {
            RoomFeedback(message, identifier: "shopping-error")
        }
        if let notice = model.notice {
            Text(notice).foregroundStyle(RoomTheme.leaf).accessibilityIdentifier("shopping-notice")
        }
        if let pending, !model.busy {
            Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Button("Retry save") { Task { await send(pending) } }
                .buttonStyle(RoomButtonStyle(kind: .primary))
        }
        Button(pending != nil || reviewRequired ? "Review latest shopping" : "Refresh shopping") {
            Task {
                let uncertain = pending != nil
                let reviewing = uncertain || reviewRequired
                if await model.refresh(), model.shopping != nil {
                    pending = nil
                    reviewRequired = false
                    if reviewing {
                        // A draft survives a review so nothing typed is lost, but an unconfirmed
                        // save has to start again from the board.
                        switch page {
                        case .form, .receipt: if uncertain { page = .board }
                        default: page = .board
                        }
                        model.notice = "Shopping refreshed. Review the current list before starting another change."
                    }
                }
            }
        }
        .buttonStyle(RoomButtonStyle(kind: .text))
        .disabled(model.busy)
    }

    private func board(_ shopping: HouseholdShopping, memberID: UUID) -> some View {
        let basket = shopping.items.filter { shopping.inBasket($0, memberID: memberID) }
        let items = section == .basket ? basket : shopping.items
        return VStack(alignment: .leading, spacing: 16) {
            RoomSegmentedPicker("Shopping sections", selection: $section, options: Section.allCases) { $0.rawValue }
                .accessibilityIdentifier("shopping-sections")
            Text("Claim what you will buy, then tick it into your basket. Ticking items never creates a debt.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            HStack {
                Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Spacer()
                if section == .list {
                    Button("Add item") { openForm(nil) }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(changesBlocked || shopping.items.count >= HouseholdShopping.itemLimit)
                }
            }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(section == .basket ? "Your basket is empty." : "What does home need?")
                        .font(RoomTheme.heading(20))
                    Text(section == .basket ? "Pick up items from the shared list first." : "Add groceries, quantities and any useful notes.")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
                .padding(.vertical, 16)
            }
            ForEach(items) { item in itemCard(item, shopping: shopping, memberID: memberID) }
            if section == .basket, !basket.isEmpty {
                Text("Recording a receipt splits it in the shared ledger and takes these items off the list.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Button("Record receipt") { openReceipt(basket: basket, memberID: memberID) }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .accessibilityIdentifier("record-basket-receipt")
                    .disabled(changesBlocked || model.ledger == nil || model.choreCalendar == nil)
            }
            if shopping.items.count >= HouseholdShopping.itemLimit {
                Text("The list has reached \(HouseholdShopping.itemLimit) items. Remove unused items or record a receipt before adding more.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
        }
    }

    private func itemCard(_ item: ShoppingItem, shopping: HouseholdShopping, memberID: UUID) -> some View {
        let editable = shopping.canEdit(item, memberID: memberID)
        return VStack(alignment: .leading, spacing: 12) {
            Text(item.name).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(item.quantity).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            if !item.notes.isEmpty { Text(item.notes).font(RoomTheme.body(14)) }
            sourceLabels(item)
            RoomSwitch("Picked up \(item.name)", isOn: Binding(
                get: { item.pickedUp }, set: { start(.pick(item, $0)) }
            ))
            .disabled(changesBlocked || !shopping.canPick(item, pickedUp: !item.pickedUp, memberID: memberID))
            Text(ownerLabel(item, shopping: shopping, memberID: memberID))
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { itemActions(item, editable: editable, shopping: shopping, memberID: memberID) }
                VStack(alignment: .leading, spacing: 8) { itemActions(item, editable: editable, shopping: shopping, memberID: memberID) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.pickedUp ? RoomTheme.leafSoft : RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopping-\(item.id.uuidString.lowercased())")
    }

    @ViewBuilder private func itemActions(_ item: ShoppingItem, editable: Bool, shopping: HouseholdShopping, memberID: UUID) -> some View {
        if item.claimedBy == nil {
            Button("I will get it") { start(.claim(item, true)) }
                .accessibilityLabel("Claim \(item.name)")
                .disabled(changesBlocked || !shopping.canClaim(item, claim: true, memberID: memberID))
        } else {
            Button("Release claim") { page = .release(item); model.clearFeedback() }
                .buttonStyle(RoomButtonStyle(kind: .text))
                .accessibilityLabel("Release claim on \(item.name)")
                .disabled(changesBlocked || !shopping.canClaim(item, claim: false, memberID: memberID))
        }
        Button("Edit") { openForm(item) }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .accessibilityLabel("Edit \(item.name)")
            .disabled(changesBlocked || !editable)
        Button("Remove", role: .destructive) { page = .remove(item); model.clearFeedback() }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .accessibilityLabel("Remove \(item.name)")
            .disabled(changesBlocked || !editable)
    }

    private func form(_ item: ShoppingItem?, shopping: HouseholdShopping, memberID: UUID) -> some View {
        let latest = item.flatMap { snapshot in shopping.items.first { $0.id == snapshot.id } }
        let blocked = item != nil && (latest == nil || latest.map { !shopping.canEdit($0, memberID: memberID) } == true)
        let changed = item != nil && latest?.version != item?.version
        return VStack(alignment: .leading, spacing: 20) {
            Text(item == nil ? "Tell your roommates what home needs. No expense is created yet."
                 : "Keep quantities and notes clear for whoever is buying it.")
                .foregroundStyle(RoomTheme.muted)
            RoomField("Item name", text: $name)
            RoomField("Quantity", text: $quantity)
            RoomField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
            if let item { sourceLabels(item) }
            if blocked {
                RoomFeedback("Item unavailable, picked up or claimed by a roommate. Close this sheet and review the list.")
            } else if changed, let latest {
                RoomFeedback("This item changed. Latest: \(latest.quantity) \(latest.name). \(latest.notes)")
                Button("Use latest item") { openForm(latest) }.disabled(changesBlocked)
                Button("Keep my draft") { page = .form(latest); model.clearFeedback(); formError = nil }
                    .disabled(changesBlocked)
            }
            Button(item == nil ? "Add to shopping list" : "Save item") {
                do {
                    let draft = try ShoppingDraft(name: name, quantity: quantity, notes: notes)
                    formError = nil
                    start(item.map { .edit($0, draft) } ?? .add(draft))
                } catch {
                    formError = "Use an item name of 1 to 50 characters, a quantity of 1 to 40 characters, and notes of up to 240 characters."
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(blocked || changed || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(changesBlocked)
    }

    private func confirmation(_ item: ShoppingItem, releasing: Bool, shopping: HouseholdShopping, memberID: UUID) -> some View {
        let latest = shopping.items.first { $0.id == item.id }
        let allowed = latest.map {
            $0.version == item.version && (releasing ? shopping.canClaim($0, claim: false, memberID: memberID)
                                          : shopping.canEdit($0, memberID: memberID))
        } ?? false
        return VStack(alignment: .leading, spacing: 16) {
            Text("\(item.quantity) \(item.name)").font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(releasing ? "This returns it to the shared list and clears its basket status. Coordinate with the shopper before buying it again."
                 : "This only changes the list, not your ledger.")
                .foregroundStyle(RoomTheme.muted)
            if !allowed { RoomFeedback("Item changed. Close this sheet and review it.") }
            Button("Cancel") { page = .board; model.clearFeedback() }.disabled(dismissalBlocked)
            Button(releasing ? "Release claim" : "Remove item") { start(releasing ? .claim(item, false) : .remove(item)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(changesBlocked || !allowed)
        }
    }

    @ViewBuilder private func sourceLabels(_ item: ShoppingItem) -> some View {
        if let sources = item.componentSources, !sources.isEmpty {
            if let catalog = model.choreCatalog {
                let labels = sources.reduce(into: [String]()) { labels, source in
                    let label = catalog.location(roomID: source.roomID, area: nil, componentName: source.componentName)
                    if !labels.contains(label) { labels.append(label) }
                }
                Text("For \(labels.joined(separator: "; "))")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            } else {
                RoomFeedback("Object details could not be displayed. Refresh shopping to try again.")
            }
        }
    }

    private func ownerLabel(_ item: ShoppingItem, shopping: HouseholdShopping, memberID: UUID) -> String {
        guard let shopper = item.claimedBy else { return "Available to claim" }
        let name = shopping.members.first { $0.id == shopper }?.name ?? "Former roommate"
        if item.pickedUp { return shopper == memberID ? "In your basket" : "In \(name)'s basket" }
        return shopper == memberID ? "You are buying this" : "\(name) is buying this"
    }

    @ViewBuilder private func receiptForm(shopping: HouseholdShopping, memberID: UUID) -> some View {
        let basket = shopping.items.filter { shopping.inBasket($0, memberID: memberID) }
        if let ledger = model.ledger, let calendar = model.choreCalendar,
           let currency = model.state?.session?.household.currency, !basket.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                ReceiptForm(
                    values: $receipt, members: ledger.activeMembers, currency: currency, calendar: calendar,
                    basket: basket, disabled: changesBlocked
                ) { draft in
                    formError = nil
                    start(.checkout(draft, UUID(), basket.map(ShoppingSelection.init)))
                }
                Button("Cancel") { page = .board; model.clearFeedback(); formError = nil }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(dismissalBlocked)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                RoomFeedback("Your basket changed. Review the list before recording a receipt.",
                             identifier: "receipt-unavailable")
                Button("Back to shopping") { page = .board; model.clearFeedback() }
                    .disabled(dismissalBlocked)
            }
        }
    }

    private func openReceipt(basket: [ShoppingItem], memberID: UUID) {
        receipt = ReceiptFormValues(
            description: "Shopping run",
            amount: "",
            category: .other,
            paidBy: memberID,
            participants: Set(model.ledger?.activeMembers.map(\.id) ?? []),
            date: model.choreCalendar.map { $0.instant(fromPickerDate: .now) } ?? .now
        )
        formError = nil
        model.clearFeedback()
        page = .receipt
    }

    private func openForm(_ item: ShoppingItem?) {
        name = item?.name ?? ""
        quantity = item?.quantity ?? "1"
        notes = item?.notes ?? ""
        formError = nil
        model.clearFeedback()
        page = .form(item)
    }

    private func start(_ change: Change) {
        guard !changesBlocked, let household = model.state?.session?.household else {
            model.message = "Refresh shopping and finish the current save before starting another change."
            return
        }
        let save = Save(householdID: household.id, version: household.version, change: change)
        pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        let saved: Bool
        switch save.change {
        case .add(let draft):
            saved = await model.addShoppingItem(draft, householdID: save.householdID, version: save.version, mutationID: save.mutationID)
        case .edit(let item, let draft):
            saved = await model.editShoppingItem(item, draft: draft, householdID: save.householdID,
                                                version: save.version, mutationID: save.mutationID)
        case .remove(let item):
            saved = await model.removeShoppingItem(item, householdID: save.householdID, version: save.version, mutationID: save.mutationID)
        case .claim(let item, let claim):
            saved = await model.claimShoppingItem(item, claim: claim, householdID: save.householdID,
                                                 version: save.version, mutationID: save.mutationID)
        case .pick(let item, let pickedUp):
            saved = await model.pickShoppingItem(item, pickedUp: pickedUp, householdID: save.householdID,
                                                version: save.version, mutationID: save.mutationID)
        case .checkout(let draft, let checkoutID, let selection):
            saved = await model.checkoutShopping(draft, checkoutID: checkoutID, selection: selection,
                                                 householdID: save.householdID, version: save.version,
                                                 mutationID: save.mutationID)
        }
        if saved {
            pending = nil
            reviewRequired = false
            page = .board
            formError = nil
            if case .add = save.change { section = .list }
            if save.change.isLedger { section = .basket }
        } else {
            switch save.change.isLedger ? model.ledgerSaveFailure : model.shoppingSaveFailure {
            case .retrySameChange: pending = save
            case .refreshRequired: pending = nil; reviewRequired = true
            case .none: pending = nil
            }
        }
    }
}
