import RoomlingsCore
import SwiftUI

/// Month and day labels shared with the web bills panel (`src/format.ts`).
enum BillDates {
    static func monthTitle(_ month: String, short: Bool = false) -> String {
        let parser = formatter("yyyy-MM-dd")
        guard let date = parser.date(from: "\(month)-15") else { return month }
        return formatter(short ? "MMM yyyy" : "MMMM yyyy").string(from: date)
    }

    /// The household's billing month, `yyyy-MM`, for a billing date.
    static func month(of day: String) -> String { String(day.prefix(7)) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

struct BillsBoardView: View {
    let bills: HouseholdBills
    let currency: HouseholdCurrency
    /// The household's billing date, `yyyy-MM-dd`.
    let today: String
    @Binding var month: String
    let blocked: Bool
    let onNew: () -> Void
    let onEdit: (Bill) -> Void
    let onPay: (Bill, BillOccurrence) -> Void
    let onPause: (Bill, Bool) -> Void
    let onUndo: (HouseholdExpense) -> Void

    private var currentMonth: String { BillDates.month(of: today) }

    var body: some View {
        let items = bills.monthlyBills(in: month, today: today)
        let earlier = bills.earlierOverdue(before: month, today: today)
        VStack(alignment: .leading, spacing: 16) {
            monthControl
            if month != currentMonth {
                Button("Back to this month") { month = currentMonth }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .accessibilityIdentifier("bills-this-month")
            }
            Text("Bills stay outside the grocery pot and fridge. Only recorded payments enter your shared balances. Dates follow \(bills.billingTimeZone).")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            if let firstMonth = earlier.firstMonth {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(earlier.count) earlier \(earlier.count == 1 ? "bill is" : "bills are") still overdue.")
                        .foregroundStyle(RoomTheme.error)
                    Button("View \(BillDates.monthTitle(firstMonth))") { month = firstMonth }
                        .buttonStyle(RoomButtonStyle(kind: .text))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("bills-earlier-overdue")
            }
            if !items.isEmpty { totals(items) }
            ForEach(items, id: \.billID) { item in occurrenceCard(item) }
            if items.isEmpty { emptyState }
            if !bills.bills.isEmpty { schedules }
            if bills.bills.count >= HouseholdBills.billLimit {
                Text("This kitchen has reached its limit of \(HouseholdBills.billLimit) monthly bills.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
        }
    }

    private var monthControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                monthStepper
                Spacer(minLength: 8)
                newBillButton
            }
            VStack(alignment: .leading, spacing: 12) {
                monthStepper
                newBillButton
            }
        }
    }

    private var monthStepper: some View {
        let first = bills.firstMonth(current: currentMonth)
        let previous = HouseholdBills.addMonths(month, -1)
        let next = HouseholdBills.addMonths(month, 1)
        return HStack(spacing: 8) {
            Button { if let previous { month = previous } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(blocked || previous == nil || month <= first)
            .accessibilityLabel("Previous bill month")
            Text(BillDates.monthTitle(month, short: true))
                .font(RoomTheme.body().weight(.semibold))
                .fixedSize()
                .accessibilityIdentifier("bills-month")
            Button { if let next { month = next } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(blocked || next == nil)
            .accessibilityLabel("Next bill month")
        }
        .buttonStyle(RoomButtonStyle(kind: .secondary))
        .fixedSize()
    }

    private var newBillButton: some View {
        Button("New monthly bill", action: onNew)
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .fixedSize()
            .accessibilityIdentifier("new-bill")
            .disabled(blocked || bills.bills.count >= HouseholdBills.billLimit)
    }

    private func totals(_ items: [BillOccurrence]) -> some View {
        let planned = items.filter { $0.payment == nil }.reduce(Int64(0)) { $0 + $1.amount }
        let recorded = items.reduce(Int64(0)) { $0 + ($1.payment?.amount ?? 0) }
        return HStack(alignment: .top, spacing: 12) {
            total("Planned, not yet recorded", planned)
            total("Recorded this billing month", recorded)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bill-totals")
    }

    private func total(_ label: String, _ amount: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
            Text(Money.text(amount, currency: currency)).font(RoomTheme.heading(20))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func occurrenceCard(_ item: BillOccurrence) -> some View {
        let bill = bills.bills.first { $0.id == item.billID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(RoomTheme.heading(20))
                    Text("Due \(ChoreCalendar.title(item.dueDate, today: today))")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
                Spacer(minLength: 8)
                statusBadge(item.status)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Money.text(item.amount, currency: currency))
                    .font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
                Text("\(item.participants.count) \(item.participants.count == 1 ? "share" : "shares")")
                    .font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
            }
            if let payment = item.payment {
                Text("Paid by \(name(payment.paidBy)) on \(ChoreCalendar.title(payment.date, today: today)).")
                    .font(RoomTheme.body(14))
                Button("Undo payment record") { onUndo(payment) }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .accessibilityLabel("Undo payment for \(item.name)")
                    .disabled(blocked)
            } else if let bill {
                Text("Confirm the actual amount and who paid before recording.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Button("Record paid") { onPay(bill, item) }
                    .buttonStyle(RoomButtonStyle(kind: .secondary))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Record payment for \(item.name)")
                    .accessibilityIdentifier("pay-bill-\(item.billID.uuidString.lowercased())")
                    .disabled(blocked)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(BillDates.monthTitle(item.month))")
        .accessibilityIdentifier("bill-\(item.billID.uuidString.lowercased())")
    }

    private func statusBadge(_ status: BillOccurrence.Status) -> some View {
        let (label, ink, soft): (String, Color, Color) = switch status {
        case .paid: ("Paid", RoomTheme.leaf, RoomTheme.leafSoft)
        case .overdue: ("Overdue", RoomTheme.error, RoomTheme.errorSoft)
        case .due: ("Due today", RoomTheme.error, RoomTheme.errorSoft)
        case .upcoming: ("Upcoming", RoomTheme.sky, RoomTheme.skySoft)
        }
        return Text(label)
            .font(RoomTheme.body(12).weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(soft, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(ink)
            .accessibilityIdentifier("bill-status")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bills.bills.isEmpty ? "Make room for the regulars." : "No bills scheduled here.")
                .font(RoomTheme.heading(20))
            Text(bills.bills.isEmpty
                 ? "Keep rent, utilities and subscriptions in the same shared ledger."
                 : "Choose another month or add a monthly bill.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bills-empty")
    }

    private var schedules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Your monthly bills").font(RoomTheme.heading(20)).accessibilityAddTraits(.isHeader)
                Text("\(bills.bills.count)")
                    .font(RoomTheme.body(12).weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(RoomTheme.surfaceMuted, in: Capsule())
            }
            Text("Edits apply to unpaid bills from this month onward. Pausing stops future months, not existing dues.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(bills.bills) { bill in scheduleCard(bill) }
        }
    }

    private func scheduleCard(_ bill: Bill) -> some View {
        let revision = bill.latestRevision
        let pause = bill.openPause
        let state = if let pause {
            pause.fromMonth > currentMonth ? "Pauses from \(BillDates.monthTitle(pause.fromMonth))." : "Paused."
        } else {
            bill.startMonth > currentMonth ? "Starts \(BillDates.monthTitle(bill.startMonth))." : "Active every month."
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(revision.name).font(RoomTheme.heading(20))
            Text("\(Money.text(revision.amount, currency: currency)) by default, due on day \(revision.dueDay).")
                .font(RoomTheme.body(14))
            Text(state).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            HStack(spacing: 10) {
                Button("Edit") { onEdit(bill) }
                    .accessibilityLabel("Edit \(revision.name)")
                    .accessibilityIdentifier("edit-bill-\(bill.id.uuidString.lowercased())")
                Button(pause == nil ? "Pause" : "Resume") { onPause(bill, pause == nil) }
                    .accessibilityLabel("\(pause == nil ? "Pause" : "Resume") \(revision.name)")
                    .accessibilityIdentifier("toggle-pause-\(bill.id.uuidString.lowercased())")
            }
            .buttonStyle(RoomButtonStyle(kind: .secondary))
            .fixedSize(horizontal: false, vertical: true)
            .disabled(blocked)
            if bill.startMonth > month {
                Button("View first month") { month = bill.startMonth }
                    .buttonStyle(RoomButtonStyle(kind: .text))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RoomTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bill-schedule-\(bill.id.uuidString.lowercased())")
    }

    private func name(_ id: UUID) -> String {
        bills.members.first { $0.id == id }?.name ?? "Former roommate"
    }
}

// MARK: - Shared split

/// Mirrors the web `SplitParticipants`: active roommates, plus any former roommate who is
/// still selected so they can be removed before saving.
private struct BillSplit: View {
    let members: [HouseholdMember]
    @Binding var selected: Set<UUID>
    let amount: Int64?
    let currency: HouseholdCurrency

    private var shown: [HouseholdMember] { members.filter { !$0.inactive || selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share it with").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(shown) { member in
                RoomSwitch(member.inactive ? "\(member.name) (former roommate)" : member.name, isOn: Binding(
                    get: { selected.contains(member.id) },
                    set: { include in
                        if include { selected.insert(member.id) } else { selected.remove(member.id) }
                    }
                ))
            }
            if let amount, amount > 0, !selected.isEmpty {
                let shares = ExpenseDraft.shares(of: amount, among: Array(selected))
                ForEach(members.filter { selected.contains($0.id) }) { member in
                    Text("\(member.name) owes \(Money.text(shares[member.id] ?? 0, currency: currency))")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bill-split")
    }
}

/// Participants in roster order, so requests do not depend on set iteration.
private func ordered(_ selected: Set<UUID>, in members: [HouseholdMember]) -> [UUID] {
    members.map(\.id).filter(selected.contains)
}

// MARK: - Editor form

struct BillEditorForm: View {
    let bill: Bill?
    let members: [HouseholdMember]
    let currency: HouseholdCurrency
    /// The household calendar once a bill exists. The first bill uses this device's time
    /// zone, which then becomes the household's billing time zone, as on the web.
    let calendar: ChoreCalendar?
    let currentMonth: String
    let disabled: Bool
    let onCreate: (BillDraft) -> Void
    let onEdit: (BillEditDraft) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var amountField = ""
    @State private var dueDay = 1
    @State private var firstDue = Date.now
    @State private var participants: Set<UUID> = []
    @State private var localError: String?
    @State private var loaded = false

    private var timeZoneName: String { calendar?.identifier ?? TimeZone.current.identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(bill == nil
                 ? "Add a monthly bill. Creating a schedule does not create a debt or move money."
                 : "Update the default amount, due day and people sharing it.")
                .foregroundStyle(RoomTheme.muted)
            RoomField("Bill name", text: $name)
                .accessibilityIdentifier("bill-name")
            RoomField("Default amount (\(currency.rawValue))", text: $amountField)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("bill-amount")
            if bill == nil {
                firstDuePicker
            } else {
                RoomPickerField("Day of month", selectedLabel: "\(dueDay)", selection: $dueDay) {
                    ForEach(1...31, id: \.self) { day in Text("\(day)").tag(day) }
                }
                .accessibilityIdentifier("bill-due-day")
            }
            Text("Repeats monthly in \(timeZoneName). Short months use their last day. You can change the actual amount when recording a payment.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            BillSplit(members: members, selected: $participants, amount: BudgetInput.cents(amountField),
                      currency: currency)
            if let bill {
                let from = bill.startMonth > currentMonth ? bill.startMonth : currentMonth
                Text("Changes apply from \(BillDates.monthTitle(from)). Earlier months and recorded payments keep their original details.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
            if let localError {
                RoomFeedback(localError, identifier: "bill-form-error")
            }
            Button(bill == nil ? "Create monthly bill" : "Save monthly bill") { submit() }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(disabled)
                .accessibilityIdentifier("confirm-bill")
            Button("Cancel", action: onCancel)
                .buttonStyle(RoomButtonStyle(kind: .text))
                .disabled(disabled)
        }
        .disabled(disabled)
        .onAppear(perform: load)
    }

    @ViewBuilder private var firstDuePicker: some View {
        if let calendar {
            DatePicker("First due date", selection: Binding(
                get: { calendar.pickerDate(firstDue) },
                set: { firstDue = calendar.instant(fromPickerDate: $0) }
            ), in: calendar.minimumDate..., displayedComponents: .date)
                .environment(\.calendar, calendar.calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier("bill-first-due")
        } else {
            DatePicker("First due date", selection: $firstDue, displayedComponents: .date)
                .accessibilityIdentifier("bill-first-due")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let revision = bill?.latestRevision {
            name = revision.name
            amountField = Money.field(revision.amount)
            dueDay = revision.dueDay
            participants = Set(revision.participants)
        } else {
            participants = Set(members.filter { !$0.inactive }.map(\.id))
        }
    }

    private func firstDueDay() -> String {
        if let calendar { return calendar.day(firstDue) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: firstDue)
    }

    private func submit() {
        guard let cents = BudgetInput.cents(amountField) else {
            localError = "Enter a positive amount with up to two decimal places."
            return
        }
        if members.contains(where: { $0.inactive && participants.contains($0.id) }) {
            localError = "Remove former roommates before saving this bill."
            return
        }
        let split = ordered(participants, in: members)
        do {
            if bill == nil {
                let day = firstDueDay()
                guard day >= "1900-01-01" else {
                    localError = "Choose a first due date from 1900 onward."
                    return
                }
                let draft = try BillDraft(name: name, amount: cents, firstDueDate: day,
                                          participants: split, timeZone: timeZoneName)
                localError = nil
                onCreate(draft)
            } else {
                let draft = try BillEditDraft(name: name, amount: cents, dueDay: dueDay, participants: split)
                localError = nil
                onEdit(draft)
            }
        } catch let error as AccountError {
            localError = error.errorDescription
        } catch {
            localError = "Check the bill name, amount and who shares it."
        }
    }
}

// MARK: - Payment form

struct BillPaymentForm: View {
    let occurrence: BillOccurrence
    /// Explains why the occurrence can no longer be recorded, after a refresh.
    let blockedReason: String?
    let members: [HouseholdMember]
    let currency: HouseholdCurrency
    let calendar: ChoreCalendar
    let disabled: Bool
    let onSave: (BillPaymentDraft) -> Void
    let onCancel: () -> Void

    @State private var amountField: String
    @State private var paidBy: UUID
    @State private var participants: Set<UUID>
    @State private var date = Date.now
    @State private var localError: String?

    init(
        occurrence: BillOccurrence, blockedReason: String?, members: [HouseholdMember], currency: HouseholdCurrency,
        calendar: ChoreCalendar, memberID: UUID, disabled: Bool,
        onSave: @escaping (BillPaymentDraft) -> Void, onCancel: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.blockedReason = blockedReason
        self.members = members
        self.currency = currency
        self.calendar = calendar
        self.disabled = disabled
        self.onSave = onSave
        self.onCancel = onCancel
        _paidBy = State(initialValue: memberID)
        _amountField = State(initialValue: Money.field(occurrence.amount))
        _participants = State(initialValue: Set(occurrence.participants))
    }

    private var payers: [HouseholdMember] { members.filter { !$0.inactive || $0.id == paidBy } }

    var body: some View {
        let today = calendar.day()
        VStack(alignment: .leading, spacing: 16) {
            Text("Only record money that has actually been paid. Roomlings does not move money.")
                .foregroundStyle(RoomTheme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.name).font(RoomTheme.heading(20)).foregroundStyle(RoomTheme.leaf)
                Text("\(BillDates.monthTitle(occurrence.month)), due \(ChoreCalendar.title(occurrence.dueDate, today: today))")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
            .accessibilityElement(children: .combine)
            RoomField("Amount paid (\(currency.rawValue))", text: $amountField)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("bill-payment-amount")
            DatePicker("Payment date", selection: Binding(
                get: { calendar.pickerDate(date) },
                set: { date = calendar.instant(fromPickerDate: $0) }
            ), in: calendar.minimumDate...calendar.pickerDate(.now), displayedComponents: .date)
                .environment(\.calendar, calendar.calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier("bill-payment-date")
            RoomPickerField("Paid by", selectedLabel: payers.first { $0.id == paidBy }.map(label) ?? "Choose a roommate",
                            selection: $paidBy) {
                ForEach(payers) { member in Text(label(member)).tag(member.id) }
            }
            BillSplit(members: members, selected: $participants, amount: BudgetInput.cents(amountField),
                      currency: currency)
            if members.contains(where: { $0.inactive && participants.contains($0.id) }) {
                Text("This schedule includes a former roommate. New payment records require active participants; review the split before recording a payment. Existing ledger entries are unchanged.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
            if let blockedReason {
                RoomFeedback(blockedReason, identifier: "bill-payment-blocked")
            }
            if let localError { RoomFeedback(localError, identifier: "bill-payment-error") }
            Button("Record bill payment") { submit(today: today) }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(disabled || blockedReason != nil)
                .accessibilityIdentifier("confirm-bill-payment")
            Text("One expense for this bill and month. No money is transferred.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Button("Cancel", action: onCancel)
                .buttonStyle(RoomButtonStyle(kind: .text))
                .disabled(disabled)
        }
        .disabled(disabled)
    }

    private func label(_ member: HouseholdMember) -> String {
        member.inactive ? "\(member.name) (former roommate)" : member.name
    }

    private func submit(today: String) {
        guard blockedReason == nil else { return }
        guard let cents = BudgetInput.cents(amountField) else {
            localError = "Enter a positive amount with up to two decimal places."
            return
        }
        if members.contains(where: { $0.inactive && ($0.id == paidBy || participants.contains($0.id)) }) {
            localError = "Choose an active payer and remove former roommates."
            return
        }
        let day = calendar.day(date)
        guard day <= today else {
            localError = "Choose a payment date on or before today."
            return
        }
        do {
            let draft = try BillPaymentDraft(
                month: occurrence.month, amount: cents, paidBy: paidBy,
                participants: ordered(participants, in: members), date: day
            )
            localError = nil
            onSave(draft)
        } catch let error as AccountError {
            localError = error.errorDescription
        } catch {
            localError = "Check the payment amount, date and who shares it."
        }
    }
}
