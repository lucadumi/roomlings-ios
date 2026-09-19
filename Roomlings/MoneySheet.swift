import RoomlingsCore
import SwiftUI

struct MoneySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountModel
    @State private var section = Section.balances
    @State private var page = Page.board
    @State private var receipt = ReceiptFormValues()
    @State private var amount = ""
    @State private var formError: String?
    @State private var pending: Save?
    @State private var reviewRequired = false
    @State private var contentHeight: CGFloat = 480
    @State private var headerHeight: CGFloat = 64

    private enum Section: String, CaseIterable {
        case balances = "Balances", receipts = "Receipts"
    }

    private enum Page {
        case board, expense, removeReceipt(HouseholdExpense)
        case settle(SuggestedTransfer), undo(HouseholdSettlement)

        var id: String {
            switch self {
            case .board: "board"
            case .expense: "expense"
            case .removeReceipt(let expense): "remove-receipt-\(expense.id)"
            case .settle(let transfer): "settle-\(transfer.id)"
            case .undo(let settlement): "undo-\(settlement.id)"
            }
        }

        var title: String {
            switch self {
            case .board: "Shared money"
            case .expense: "Record a paid receipt."
            case .removeReceipt: "Remove this receipt?"
            case .settle: "Record a repayment."
            case .undo: "Undo this repayment?"
            }
        }
    }

    private enum Change {
        case record(ExpenseDraft), removeReceipt(HouseholdExpense)
        case settle(from: UUID, to: UUID, amount: Int64), undo(HouseholdSettlement)
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
                        feedback.id("money-feedback")
                        if let ledger = model.ledger, let session = model.state?.session, model.canUseAccount {
                            let currency = session.household.currency
                            switch page {
                            case .board: board(ledger, currency: currency, memberID: session.memberID)
                            case .expense: expenseForm(ledger, currency: currency, memberID: session.memberID)
                            case .removeReceipt(let expense): receiptRemoval(expense, ledger: ledger, currency: currency, memberID: session.memberID)
                            case .settle(let transfer): settleForm(transfer, ledger: ledger, currency: currency)
                            case .undo(let settlement): undoForm(settlement, ledger: ledger, currency: currency)
                            }
                        } else {
                            Text(model.ledgerFailure ?? "Open a household to see its shared money.")
                                .foregroundStyle(RoomTheme.error)
                                .accessibilityIdentifier("money-unavailable")
                        }
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .id(page.id)
                .scrollDismissesKeyboard(.interactively)
                .disabled(model.busy)
                .onChange(of: model.message) { _, message in
                    if message != nil { proxy.scrollTo("money-feedback", anchor: .top) }
                }
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { proxy.scrollTo("money-feedback", anchor: .top) }
                }
                .onChange(of: formError) { _, error in
                    if error != nil { proxy.scrollTo("money-feedback", anchor: .top) }
                }
            }
            .modifier(RoomSheetLoading(model: model, label: "Loading money..."))
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .tint(RoomTheme.sage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("money-sheet")
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(dismissalBlocked)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
    }

    @ViewBuilder private var feedback: some View {
        if model.busy {
            HStack {
                RoomLoadingIcon()
                Text(pending == nil ? "Refreshing money..." : "Saving to the ledger...")
            }
            .accessibilityIdentifier("money-progress")
        }
        if let message = model.message ?? formError {
            Text(message)
                .foregroundStyle(RoomTheme.error)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoomTheme.errorSoft, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                .accessibilityIdentifier("money-error")
        }
        if let notice = model.notice {
            Text(notice).foregroundStyle(RoomTheme.leaf).accessibilityIdentifier("money-notice")
        }
        if let pending, !model.busy {
            Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Button("Retry save") { Task { await send(pending) } }
                .buttonStyle(RoomButtonStyle(kind: .primary))
        }
        Button(pending != nil || reviewRequired ? "Review latest money" : "Refresh money") {
            Task {
                let uncertain = pending != nil
                let reviewing = uncertain || reviewRequired
                if await model.refresh(), model.ledger != nil {
                    pending = nil
                    reviewRequired = false
                    if reviewing {
                        // A typed draft survives a review; an unconfirmed save starts again.
                        switch page {
                        case .expense, .settle: if uncertain { page = .board }
                        default: page = .board
                        }
                        model.notice = "Money refreshed. Review the latest balances before starting another change."
                    }
                }
            }
        }
        .buttonStyle(RoomButtonStyle(kind: .text))
        .disabled(model.busy)
    }

    private func board(_ ledger: HouseholdLedger, currency: HouseholdCurrency, memberID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            RoomSegmentedPicker("Money sections", selection: $section, options: Section.allCases) { $0.rawValue }
                .accessibilityIdentifier("money-sections")
            Text("Roomlings only tracks what everyone owes. It never moves money between you.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                .accessibilityIdentifier("money-disclaimer")
            if section == .balances {
                balanceList(ledger, currency: currency)
                repaymentList(ledger, currency: currency)
                settlementHistory(ledger, currency: currency)
            } else {
                receiptList(ledger, currency: currency, memberID: memberID)
            }
        }
    }

    @ViewBuilder private func balanceList(_ ledger: HouseholdLedger, currency: HouseholdCurrency) -> some View {
        let shown = ledger.balances.filter { !$0.member.inactive || $0.amount != 0 }
        Text("Who is square").font(RoomTheme.heading(20))
        if shown.allSatisfy({ $0.amount == 0 }) {
            Text("Everyone is settled up.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                .accessibilityIdentifier("all-settled")
        }
        ForEach(shown) { balance in
            HStack(alignment: .firstTextBaseline) {
                Text(balance.member.name).font(RoomTheme.body())
                Spacer(minLength: 8)
                Text(balanceLabel(balance, currency: currency))
                    .foregroundStyle(balance.amount == 0 ? RoomTheme.muted : (balance.isOwed ? RoomTheme.leaf : RoomTheme.error))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("balance-\(balance.member.id.uuidString.lowercased())")
        }
    }

    @ViewBuilder private func repaymentList(_ ledger: HouseholdLedger, currency: HouseholdCurrency) -> some View {
        let transfers = ledger.suggestedTransfers
        if !transfers.isEmpty {
            Text("Settle up").font(RoomTheme.heading(20))
            Text("Record a repayment once it has actually been paid.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(transfers) { transfer in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name(transfer.from, in: ledger)) pays \(name(transfer.to, in: ledger))")
                        .font(RoomTheme.body())
                    Text(Money.text(transfer.amount, currency: currency))
                        .font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
                    Button("Record repayment") { openSettle(transfer, currency: currency) }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .accessibilityLabel("Record \(name(transfer.from, in: ledger)) paying \(name(transfer.to, in: ledger))")
                        .disabled(changesBlocked)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transfer-\(transfer.from.uuidString.lowercased())-\(transfer.to.uuidString.lowercased())")
            }
        }
    }

    @ViewBuilder private func settlementHistory(_ ledger: HouseholdLedger, currency: HouseholdCurrency) -> some View {
        if !ledger.settlements.isEmpty {
            Text("Recorded repayments").font(RoomTheme.heading(20))
            ForEach(ledger.settlements) { settlement in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name(settlement.from, in: ledger)) paid \(name(settlement.to, in: ledger))")
                        .font(RoomTheme.body())
                    Text(Money.text(settlement.amount, currency: currency)).font(RoomTheme.heading(20))
                    Button("Undo repayment", role: .destructive) { page = .undo(settlement); model.clearFeedback() }
                        .buttonStyle(RoomButtonStyle(kind: .text))
                        .accessibilityLabel("Undo \(name(settlement.from, in: ledger)) paying \(name(settlement.to, in: ledger))")
                        .disabled(changesBlocked)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settlement-\(settlement.id.uuidString.lowercased())")
            }
        }
    }

    @ViewBuilder private func receiptList(_ ledger: HouseholdLedger, currency: HouseholdCurrency, memberID: UUID) -> some View {
        HStack {
            Text("\(ledger.expenses.count) \(ledger.expenses.count == 1 ? "receipt" : "receipts")")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Spacer()
            Button("Record expense") { openExpense(memberID: memberID) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("record-expense")
                .disabled(changesBlocked || model.choreCalendar == nil
                          || ledger.expenses.count >= HouseholdLedger.expenseLimit)
        }
        if ledger.expenses.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No receipts yet.").font(RoomTheme.heading(20))
                Text("Record what you paid and Roomlings splits it for you.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
            .padding(.vertical, 16)
        }
        ForEach(ledger.expenses) { expense in
            receiptCard(expense, ledger: ledger, currency: currency, memberID: memberID)
        }
    }

    private func receiptCard(
        _ expense: HouseholdExpense, ledger: HouseholdLedger, currency: HouseholdCurrency, memberID: UUID
    ) -> some View {
        let shares = expense.shares
        return VStack(alignment: .leading, spacing: 12) {
            Text(expense.description).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(Money.text(expense.amount, currency: currency)).font(RoomTheme.heading(20))
            Text("\(name(expense.paidBy, in: ledger)) paid on \(expense.date)")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Text(expense.category.label).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(expense.participants, id: \.self) { participant in
                Text("\(name(participant, in: ledger)) owes \(Money.text(shares[participant] ?? 0, currency: currency))")
                    .font(RoomTheme.body(14))
            }
            if expense.shoppingRunID != nil {
                Text("Recorded from a shopping run. Remove it on the web so its run history stays correct.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            } else if expense.isBillPayment {
                Text("This is a bill payment. Manage it on the web.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            } else {
                Button("Remove receipt", role: .destructive) { page = .removeReceipt(expense); model.clearFeedback() }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .accessibilityLabel("Remove \(expense.description)")
                    .disabled(changesBlocked || !ledger.canRemove(expense, memberID: memberID))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt-\(expense.id.uuidString.lowercased())")
    }

    @ViewBuilder private func expenseForm(_ ledger: HouseholdLedger, currency: HouseholdCurrency, memberID: UUID) -> some View {
        if let calendar = model.choreCalendar {
            VStack(alignment: .leading, spacing: 20) {
                ReceiptForm(
                    values: $receipt, members: ledger.activeMembers, currency: currency, calendar: calendar,
                    basket: [], disabled: changesBlocked
                ) { draft in
                    formError = nil
                    start(.record(draft))
                }
                Button("Cancel") { page = .board; model.clearFeedback(); formError = nil }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(dismissalBlocked)
            }
        } else {
            unavailable("Receipts are unavailable. Refresh money and try again.")
        }
    }

    private func receiptRemoval(
        _ expense: HouseholdExpense, ledger: HouseholdLedger, currency: HouseholdCurrency, memberID: UUID
    ) -> some View {
        let allowed = ledger.canRemove(expense, memberID: memberID)
        return VStack(alignment: .leading, spacing: 16) {
            Text(expense.description).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(Money.text(expense.amount, currency: currency)).font(RoomTheme.heading(20))
            Text("This takes the receipt out of the shared ledger for everyone. It cannot be edited back.")
                .foregroundStyle(RoomTheme.muted)
            if !allowed {
                Text("This receipt changed or cannot be removed here. Refresh money and review the ledger.")
                    .foregroundStyle(RoomTheme.error)
            }
            Button("Cancel") { page = .board; model.clearFeedback() }.disabled(dismissalBlocked)
            Button("Remove receipt") { start(.removeReceipt(expense)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .accessibilityIdentifier("confirm-remove-receipt")
                .disabled(changesBlocked || !allowed)
        }
    }

    private func settleForm(_ transfer: SuggestedTransfer, ledger: HouseholdLedger, currency: HouseholdCurrency) -> some View {
        let cents = BudgetInput.cents(amount)
        let allowed = cents.map { ledger.canSettle(from: transfer.from, to: transfer.to, amount: $0) } ?? false
        return VStack(alignment: .leading, spacing: 20) {
            Text("\(name(transfer.from, in: ledger)) pays \(name(transfer.to, in: ledger))")
                .font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text("Record this only after the money has actually changed hands. Roomlings never moves it for you.")
                .foregroundStyle(RoomTheme.muted)
            Text("Suggested: \(Money.text(transfer.amount, currency: currency))")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            RoomField("Repayment amount", text: $amount)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("repayment-amount-field")
            if cents != nil && !allowed {
                Text("These balances only allow up to \(Money.text(transfer.amount, currency: currency)) between them.")
                    .foregroundStyle(RoomTheme.error)
                    .accessibilityIdentifier("repayment-error")
            }
            Button("Cancel") { page = .board; model.clearFeedback(); formError = nil }
                .buttonStyle(RoomButtonStyle(kind: .text))
                .disabled(dismissalBlocked)
            Button("Record repayment") {
                guard let cents, ledger.canSettle(from: transfer.from, to: transfer.to, amount: cents) else {
                    formError = "Enter an amount these balances allow, from 0.01 upwards."
                    return
                }
                formError = nil
                start(.settle(from: transfer.from, to: transfer.to, amount: cents))
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .accessibilityIdentifier("confirm-repayment")
            .disabled(changesBlocked || !allowed)
        }
    }

    private func undoForm(_ settlement: HouseholdSettlement, ledger: HouseholdLedger, currency: HouseholdCurrency) -> some View {
        let present = ledger.settlements.contains(settlement)
        return VStack(alignment: .leading, spacing: 16) {
            Text("\(name(settlement.from, in: ledger)) paid \(name(settlement.to, in: ledger))")
                .font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text(Money.text(settlement.amount, currency: currency)).font(RoomTheme.heading(20))
            Text("Undoing puts this amount back on the balances for everyone. No money moves either way.")
                .foregroundStyle(RoomTheme.muted)
            if !present {
                Text("This repayment is no longer in the ledger. Refresh money and review the balances.")
                    .foregroundStyle(RoomTheme.error)
            }
            Button("Cancel") { page = .board; model.clearFeedback() }.disabled(dismissalBlocked)
            Button("Undo repayment") { start(.undo(settlement)) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .accessibilityIdentifier("confirm-undo-repayment")
                .disabled(changesBlocked || !present)
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message).foregroundStyle(RoomTheme.error).accessibilityIdentifier("money-form-unavailable")
            Button("Back to money") { page = .board; model.clearFeedback() }.disabled(dismissalBlocked)
        }
    }

    private func balanceLabel(_ balance: MemberBalance, currency: HouseholdCurrency) -> String {
        if balance.amount == 0 { return "Settled up" }
        let amount = Money.text(abs(balance.amount), currency: currency)
        return balance.isOwed ? "Is owed \(amount)" : "Owes \(amount)"
    }

    private func name(_ id: UUID, in ledger: HouseholdLedger) -> String {
        ledger.member(id)?.name ?? "Former roommate"
    }

    private func openExpense(memberID: UUID) {
        receipt = ReceiptFormValues(
            description: "", amount: "", category: .other, paidBy: memberID,
            participants: Set(model.ledger?.activeMembers.map(\.id) ?? []),
            date: model.choreCalendar.map { $0.instant(fromPickerDate: .now) } ?? .now
        )
        formError = nil
        model.clearFeedback()
        page = .expense
    }

    private func openSettle(_ transfer: SuggestedTransfer, currency: HouseholdCurrency) {
        amount = Money.field(transfer.amount)
        formError = nil
        model.clearFeedback()
        page = .settle(transfer)
    }

    private func start(_ change: Change) {
        guard !changesBlocked, let household = model.state?.session?.household else {
            model.message = "Refresh money and finish the current save before starting another change."
            return
        }
        let save = Save(householdID: household.id, version: household.version, change: change)
        pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        let saved: Bool
        switch save.change {
        case .record(let draft):
            saved = await model.recordExpense(draft, householdID: save.householdID,
                                              version: save.version, mutationID: save.mutationID)
        case .removeReceipt(let expense):
            saved = await model.removeExpense(expense, householdID: save.householdID,
                                              version: save.version, mutationID: save.mutationID)
        case .settle(let from, let to, let cents):
            saved = await model.recordSettlement(from: from, to: to, amount: cents, householdID: save.householdID,
                                                 version: save.version, mutationID: save.mutationID)
        case .undo(let settlement):
            saved = await model.removeSettlement(settlement, householdID: save.householdID,
                                                 version: save.version, mutationID: save.mutationID)
        }
        if saved {
            pending = nil
            reviewRequired = false
            page = .board
            formError = nil
            if case .record = save.change { section = .receipts } else { section = .balances }
        } else {
            switch model.ledgerSaveFailure {
            case .retrySameChange: pending = save
            case .refreshRequired: pending = nil; reviewRequired = true
            case .none: pending = nil
            }
        }
    }
}
