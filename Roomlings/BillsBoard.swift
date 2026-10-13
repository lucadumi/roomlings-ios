import RoomlingsCore
import SwiftUI

struct BillsBoardView: View {
    let bills: HouseholdBills
    let currency: HouseholdCurrency
    let today: Date
    let blocked: Bool
    let onNew: () -> Void
    let onEdit: (Bill) -> Void
    let onPay: (Bill, BillOccurrence) -> Void
    let onTogglePause: (Bill) -> Void

    private var currentMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: bills.billingTimeZone) ?? .current
        f.dateFormat = "yyyy-MM"
        return f.string(from: today)
    }

    private var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: bills.billingTimeZone) ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(bills.bills.count) \(bills.bills.count == 1 ? "bill" : "bills")")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Spacer()
                Button("New bill", action: onNew)
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("new-bill")
                    .disabled(blocked || bills.bills.count >= HouseholdBills.billLimit)
            }
            Text("Recurring bills split between roommates. Roomlings only tracks them; it never pays.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)

            if bills.bills.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No bills yet.").font(RoomTheme.heading(20))
                    Text("Add rent, internet or anything that repeats each month.")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
                .padding(.vertical, 16)
            }

            ForEach(bills.bills) { bill in
                billCard(bill)
            }
        }
    }

    @ViewBuilder private func billCard(_ bill: Bill) -> some View {
        let occurrence = bills.occurrence(of: bill, in: currentMonth)
        let revision = bill.revision(for: occurrence?.month ?? currentMonth)
        let status = status(for: bill, occurrence: occurrence)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(revision?.name ?? "Bill").font(RoomTheme.heading(20))
                Spacer(minLength: 8)
                if let amount = revision?.amount {
                    Text(Money.text(amount, currency: currency)).font(RoomTheme.heading(20))
                }
            }
            HStack(spacing: 8) {
                billBadge(status)
                if let due = occurrence?.dueDate, status != .paid {
                    Text("Due \(due)").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
            }
            HStack(spacing: 10) {
                if status == .due || status == .overdue, let occ = occurrence {
                    Button("Record payment") { onPay(bill, occ) }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .disabled(blocked)
                        .accessibilityIdentifier("pay-bill-\(bill.id.uuidString.lowercased())")
                }
                Button(bill.isPaused ? "Resume" : "Pause") { onTogglePause(bill) }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(blocked)
                    .accessibilityIdentifier("toggle-pause-\(bill.id.uuidString.lowercased())")
                Button("Edit") { onEdit(bill) }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(blocked)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bill-\(bill.id.uuidString.lowercased())")
    }

    private enum BillStatus { case paused, paid, due, overdue, upcoming }

    private func status(for bill: Bill, occurrence: BillOccurrence?) -> BillStatus {
        if bill.isPaused { return .paused }
        guard let occ = occurrence else { return .upcoming }
        if occ.payment != nil { return .paid }
        return occ.dueDate < todayString ? .overdue : .due
    }

    @ViewBuilder private func billBadge(_ status: BillStatus) -> some View {
        let (label, tint): (String, Color) = {
            switch status {
            case .paused: ("Paused", RoomTheme.muted)
            case .paid: ("Paid", RoomTheme.leaf)
            case .due: ("Due", RoomTheme.error)
            case .overdue: ("Overdue", RoomTheme.error)
            case .upcoming: ("Upcoming", RoomTheme.leaf)
            }
        }()
        Text(label)
            .font(RoomTheme.body(12))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Editor form

struct BillEditorForm: View {
    enum Mode {
        case new(defaultMember: UUID)
        case edit(Bill)
    }

    let mode: Mode
    let members: [HouseholdMember]
    let currency: HouseholdCurrency
    let disabled: Bool
    let onSave: (BillDraft) -> Void
    let onSaveEdit: (BillEditDraft) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var amountField = ""
    @State private var dueDay = 1
    @State private var firstDue = Date()
    @State private var participants: Set<UUID> = []
    @State private var localError: String?

    init(
        mode: Mode,
        members: [HouseholdMember],
        currency: HouseholdCurrency,
        disabled: Bool,
        onSave: @escaping (BillDraft) -> Void = { _ in },
        onSaveEdit: @escaping (BillEditDraft) -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.members = members
        self.currency = currency
        self.disabled = disabled
        self.onSave = onSave
        self.onSaveEdit = onSaveEdit
        self.onCancel = onCancel
    }

    private var isNew: Bool { if case .new = mode { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isNew {
                RoomField("Bill name", text: $name)
                    .accessibilityIdentifier("bill-name")
                RoomField("Amount", text: $amountField)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("bill-amount")
                DatePicker("First due date", selection: $firstDue, displayedComponents: .date)
                    .font(RoomTheme.body())
            } else if case .edit(let bill) = mode {
                RoomField("Bill name", text: $name)
                RoomField("Amount", text: $amountField).keyboardType(.decimalPad)
                Stepper("Due day \(dueDay)", value: $dueDay, in: 1...31)
            }

            Text("Split between").font(RoomTheme.heading(20))
            ForEach(members) { member in
                Toggle(member.name, isOn: Binding(
                    get: { participants.contains(member.id) },
                    set: { on in
                        if on { participants.insert(member.id) } else { participants.remove(member.id) }
                    }
                ))
            }
            if let localError {
                RoomFeedback(localError, identifier: "bill-form-error")
            }
            Button("Cancel", action: onCancel).disabled(disabled)
            Button(isNew ? "Create bill" : "Save changes") { submit() }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(disabled || !canSave)
                .accessibilityIdentifier("confirm-bill")
        }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && cents > 0 && !participants.isEmpty && participants.count <= 12
    }

    private var cents: Int64 {
        BudgetInput.cents(amountField) ?? 0
    }

    private func load() {
        switch mode {
        case .new(let me):
            participants = [me]
        case .edit(let bill):
            guard let rev = bill.revisions.last else { return }
            name = rev.name
            amountField = Money.field(rev.amount)
            dueDay = rev.dueDay
            participants = Set(rev.participants)
        }
    }

    private func submit() {
        localError = nil
        do {
            switch mode {
            case .new:
                let draft = try BillDraft(
                    name: name, amount: cents,
                    firstDueDate: dateString(firstDue),
                    participants: Array(participants)
                )
                onSave(draft)
            case .edit:
                let draft = try BillEditDraft(
                    name: name, amount: cents, dueDay: dueDay, participants: Array(participants)
                )
                onSaveEdit(draft)
            }
        } catch let account as AccountError {
            localError = account.errorDescription
        } catch {
            localError = "Check the bill fields."
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Payment form

struct BillPaymentForm: View {
    let bill: Bill
    let occurrence: BillOccurrence
    let members: [HouseholdMember]
    let currency: HouseholdCurrency
    let defaultMember: UUID
    let disabled: Bool
    let onSave: (BillPaymentDraft) -> Void
    let onCancel: () -> Void

    @State private var amountField = ""
    @State private var paidBy: UUID
    @State private var participants: Set<UUID> = []
    @State private var date = Date()
    @State private var localError: String?

    init(
        bill: Bill, occurrence: BillOccurrence, members: [HouseholdMember], currency: HouseholdCurrency,
        defaultMember: UUID, disabled: Bool,
        onSave: @escaping (BillPaymentDraft) -> Void, onCancel: @escaping () -> Void
    ) {
        self.bill = bill
        self.occurrence = occurrence
        self.members = members
        self.currency = currency
        self.defaultMember = defaultMember
        self.disabled = disabled
        self.onSave = onSave
        self.onCancel = onCancel
        _paidBy = State(initialValue: defaultMember)
        _amountField = State(initialValue: Money.field(occurrence.amount))
        _participants = State(initialValue: Set(occurrence.participants))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(occurrence.name).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
            Text("Due \(occurrence.dueDate)").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Text("Record this only after the money has actually changed hands.")
                .foregroundStyle(RoomTheme.muted)

            RoomField("Amount", text: $amountField).keyboardType(.decimalPad)
                .accessibilityIdentifier("bill-payment-amount")
            Picker("Paid by", selection: $paidBy) {
                ForEach(members) { member in
                    Text(member.name).tag(member.id)
                }
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)

            Text("Split between").font(RoomTheme.heading(20))
            ForEach(members) { member in
                Toggle(member.name, isOn: Binding(
                    get: { participants.contains(member.id) },
                    set: { on in
                        if on { participants.insert(member.id) } else { participants.remove(member.id) }
                    }
                ))
            }

            if let localError { RoomFeedback(localError, identifier: "bill-payment-error") }

            Button("Cancel", action: onCancel).disabled(disabled)
            Button("Record payment") { submit() }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(disabled || cents <= 0 || participants.isEmpty)
                .accessibilityIdentifier("confirm-bill-payment")
        }
    }

    private var cents: Int64 { BudgetInput.cents(amountField) ?? 0 }

    private func submit() {
        localError = nil
        do {
            let draft = try BillPaymentDraft(
                month: occurrence.month, amount: cents, paidBy: paidBy,
                participants: Array(participants), date: dateString(date)
            )
            onSave(draft)
        } catch let account as AccountError {
            localError = account.errorDescription
        } catch {
            localError = "Check the payment fields."
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
