import RoomlingsCore
import SwiftUI

struct AccountHouseRulesSection: View {
    /// The draft lives with the sheet because account refreshes replace the sheet's content.
    struct Form {
        var name = ""
        var budget = ""
        var currency = HouseholdCurrency.eur
        var reviewed: HouseholdSettings?
        var pending: Save?
        var reviewRequired = false
        var formError: String?
    }

    struct Save {
        let householdID: UUID
        let version: Int64
        let mutationID = UUID()
        let draft: HouseholdSettingsDraft
    }

    @Bindable var model: AccountModel
    @Binding var form: Form
    let onSaved: () -> Void
    @Environment(\.roomControlAppearance) private var controlAppearance

    private var changesBlocked: Bool { model.busy || form.pending != nil || form.reviewRequired }

    var body: some View {
        AccountSection("House rules") {
            if let rules = model.houseRules, let household = model.state?.session?.household {
                Text("A shared budget keeps everyone on the same page.").foregroundStyle(RoomTheme.muted)
                RoomField("Household name", text: $form.name)
                    .disabled(changesBlocked)
                RoomField("Monthly grocery budget", text: $form.budget)
                    .keyboardType(.decimalPad)
                    .disabled(changesBlocked)
                currencyField(locked: rules.currencyLocked)
                Text(rules.currencyLocked
                     ? "The monthly grocery target applies to every month. Currency stays fixed after adding expenses or monthly bills."
                     : "The monthly grocery target applies to every month.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                if let reviewed = form.reviewed, !reviewed.sameRules(as: rules), form.pending == nil {
                    RoomFeedback("The house rules changed. Review the latest values before saving your draft.",
                                 identifier: "house-rules-conflict") {
                        Button("Use the latest values") { load(rules) }
                        Button("Keep my draft") {
                            form.reviewed = rules
                            form.formError = nil
                        }
                    }
                }
                if let formError = form.formError { RoomFeedback(formError, identifier: "house-rules-error") }
                if let pending = form.pending, !model.busy {
                    Text("This save is not confirmed. Retrying sends the same change, not a new one.")
                        .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    Button("Retry save") { Task { await send(pending) } }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                }
                if form.pending != nil || form.reviewRequired {
                    Button("Review latest house rules") { Task { await review() } }
                        .accessibilityIdentifier("review-house-rules")
                } else {
                    Button(model.busy ? "Saving..." : "Save the house rules") { start(rules, household: household) }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .disabled(model.busy || form.reviewed?.sameRules(as: rules) == false)
                        .accessibilityIdentifier("save-house-rules")
                }
            } else {
                Text(model.houseRulesFailure ?? "Open a household to change its house rules.")
                Button("Refresh account") { Task { await review() } }
            }
        }
        .onAppear { if form.reviewed == nil, let rules = model.houseRules { load(rules) } }
        .onChange(of: form.name) { form.formError = nil }
        .onChange(of: form.budget) { form.formError = nil }
        .onChange(of: form.currency) { form.formError = nil }
    }

    @ViewBuilder private func currencyField(locked: Bool) -> some View {
        if controlAppearance == .roomlings {
            RoomPickerField("Currency", selectedLabel: form.currency.rawValue, selection: $form.currency) {
                ForEach(HouseholdCurrency.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
            }
            .disabled(changesBlocked || locked)
        } else {
            Picker("Currency", selection: $form.currency) {
                ForEach(HouseholdCurrency.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
            }
            .disabled(changesBlocked || locked)
            .accessibilityIdentifier("Currency")
        }
    }

    private func load(_ rules: HouseholdSettings) {
        form.name = rules.name
        form.budget = "\(rules.budget / 100).\(String(format: "%02lld", rules.budget % 100))"
        form.currency = rules.currency
        form.reviewed = rules
        form.formError = nil
    }

    private func start(_ rules: HouseholdSettings, household: HouseholdSnapshot) {
        guard !changesBlocked else { return }
        guard let cents = BudgetInput.cents(form.budget) else {
            form.formError = "Enter a budget from 0.01 to 1,000,000.00, with at most two decimal places."
            return
        }
        let draft: HouseholdSettingsDraft
        do {
            draft = try HouseholdSettingsDraft(name: form.name, budget: cents, currency: rules.currencyLocked ? rules.currency : form.currency)
        } catch {
            form.formError = "Enter a household name with at most 50 characters."
            return
        }
        let save = Save(householdID: household.id, version: household.version, draft: draft)
        form.pending = save
        Task { await send(save) }
    }

    private func send(_ save: Save) async {
        if await model.saveHouseRules(save.draft, householdID: save.householdID, version: save.version, mutationID: save.mutationID) {
            form.pending = nil
            onSaved()
            return
        }
        switch model.houseRulesSaveFailure {
        case .retrySameChange: form.pending = save
        case .refreshRequired: form.pending = nil; form.reviewRequired = true
        case .none: form.pending = nil
        }
    }

    private func review() async {
        let uncertain = form.pending != nil
        guard await model.refresh(), let rules = model.houseRules else { return }
        form.pending = nil
        form.reviewRequired = false
        // An unconfirmed save may have landed, so the form shows what the server holds.
        if uncertain || form.reviewed == nil { load(rules) }
        model.notice = "House rules refreshed. Review the latest values before saving."
    }
}
