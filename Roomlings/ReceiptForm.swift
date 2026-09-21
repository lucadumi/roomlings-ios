import RoomlingsCore
import SwiftUI

struct ReceiptFormValues {
    var description = ""
    var amount = ""
    var category = ExpenseCategory.other
    var paidBy: UUID?
    var participants: Set<UUID> = []
    var date = Date.now
}

/// Collects one paid receipt. The shared server stays authoritative for the ledger, so this
/// only previews the same whole-cent split it will apply.
struct ReceiptForm: View {
    @Binding var values: ReceiptFormValues
    let members: [HouseholdMember]
    let currency: HouseholdCurrency
    let calendar: ChoreCalendar
    let basket: [ShoppingItem]
    let disabled: Bool
    let onSubmit: (ExpenseDraft) -> Void
    @State private var error: String?

    private var orderedParticipants: [UUID] {
        members.map(\.id).filter { values.participants.contains($0) }
    }

    private var preview: ExpenseDraft? {
        guard let paidBy = values.paidBy, let amount = BudgetInput.cents(values.amount) else { return nil }
        return try? ExpenseDraft(
            description: values.description, amount: amount, paidBy: paidBy,
            participants: orderedParticipants, category: values.category, date: calendar.day(values.date)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(basket.isEmpty
                 ? "Record what you already paid. This adds it to the shared ledger."
                 : "Record what you paid for your basket. These items leave the shared list.")
                .foregroundStyle(RoomTheme.muted)
            if !basket.isEmpty { basketSummary }
            RoomField("Receipt name", text: $values.description)
                .accessibilityIdentifier("receipt-name-field")
            RoomField("Amount", text: $values.amount)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("receipt-amount-field")
            RoomPickerField("Category", selectedLabel: values.category.label, selection: $values.category) {
                ForEach(ExpenseCategory.allCases) { category in Text(category.label).tag(category) }
            }
            RoomPickerField("Who paid", selectedLabel: values.paidBy.map(memberName) ?? "Choose a roommate",
                            selection: $values.paidBy) {
                if values.paidBy == nil { Text("Choose a roommate").tag(Optional<UUID>.none) }
                ForEach(members) { member in Text(member.name).tag(Optional(member.id)) }
            }
            DatePicker("Receipt date", selection: Binding(
                get: { calendar.pickerDate(values.date) },
                set: { values.date = calendar.instant(fromPickerDate: $0) }
            ), in: calendar.minimumDate..., displayedComponents: .date)
                .environment(\.calendar, calendar.calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier("receipt-date")
            split
            if let error { RoomFeedback(error, identifier: "receipt-form-error") }
            Button("Record receipt") { submit() }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .accessibilityIdentifier("record-receipt")
                .disabled(disabled || preview == nil)
        }
        .disabled(disabled)
    }

    private var basketSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(basket.count) \(basket.count == 1 ? "item" : "items") from your basket")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(basket) { item in
                Text("\(item.quantity) \(item.name)").font(RoomTheme.body(14))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTheme.leafSoft, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt-basket")
    }

    private var split: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split between").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            ForEach(members) { member in
                RoomSwitch(member.name, isOn: Binding(
                    get: { values.participants.contains(member.id) },
                    set: { include in
                        if include { values.participants.insert(member.id) }
                        else { values.participants.remove(member.id) }
                    }
                ))
            }
            if let preview {
                let shares = preview.shares
                ForEach(members.filter { values.participants.contains($0.id) }) { member in
                    Text("\(member.name) owes \(Money.text(shares[member.id] ?? 0, currency: currency))")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                }
                Text("The server records the same whole-cent split.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt-split")
    }

    private func memberName(_ id: UUID) -> String {
        members.first { $0.id == id }?.name ?? "Former roommate"
    }

    private func submit() {
        guard let paidBy = values.paidBy, members.contains(where: { $0.id == paidBy }) else {
            error = "Choose an active roommate who paid."
            return
        }
        let participants = orderedParticipants
        guard !participants.isEmpty else {
            error = "Choose at least one roommate to split this with."
            return
        }
        guard let amount = BudgetInput.cents(values.amount) else {
            error = "Enter an amount from 0.01 to 1,000,000.00, with at most two decimal places."
            return
        }
        do {
            let draft = try ExpenseDraft(
                description: values.description, amount: amount, paidBy: paidBy,
                participants: participants, category: values.category, date: calendar.day(values.date)
            )
            error = nil
            onSubmit(draft)
        } catch {
            self.error = "Use a receipt name of 1 to 100 characters, a valid date and at most 12 roommates."
        }
    }
}
