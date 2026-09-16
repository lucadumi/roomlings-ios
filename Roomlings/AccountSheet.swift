import RoomlingsCore
import SwiftUI

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.roomControlAppearance) private var controlAppearance
    @Bindable var model: AccountModel
    @State private var page = Page.email
    @State private var email = ""
    @State private var emailCode = ""
    @State private var displayName = ""
    @State private var recoveryCode = ""
    @State private var deviceLabel = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    @State private var householdName = ""
    @State private var memberName = ""
    @State private var budget = "300.00"
    @State private var currency = HouseholdCurrency.eur
    @State private var creationID = UUID()
    @State private var confirmingSignOut = false
    @State private var contentHeight: CGFloat = 320
    @State private var headerHeight: CGFloat = 64

    private enum Page { case email, verify, recover, account, create, join }
    @State private var invitation = ""
    private let currencies: [HouseholdCurrency] = [.eur, .usd, .gbp, .ron]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if page == .create || page == .join || (!model.signedIn && page != .email) {
                    Button("Back") {
                        model.clearFeedback()
                        page = model.signedIn ? .account : .email
                    }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(model.busy)
                }
                Text(title)
                    .font(RoomTheme.heading())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button(model.signedIn ? "Done" : "Not now") { dismiss() }
                    .buttonStyle(RoomButtonStyle(kind: .text))
                    .disabled(model.busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    feedback
                    if let setupError = model.setupError {
                        AccountSection { Text(setupError) }
                    } else if model.deletionPending {
                        AccountSection("Account deletion") {
                            Text("Deletion is pending. Finish it on the web. Household access stays closed.")
                        }
                        accountActions
                    } else if model.signedIn {
                        switch page {
                        case .create: createForm
                        case .join: joinForm
                        default: households
                        }
                    } else if model.state?.configured == false {
                        AccountSection { Text("Account access is not configured on this server.") }
                        Button("Refresh account") { Task { await model.refresh() } }
                    } else {
                        switch page {
                        case .verify: verifyForm
                        case .recover: recoveryForm
                        default: emailForm
                        }
                    }
                }
                .padding(24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(model.busy)
            .confirmationDialog("Sign out on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        if await model.signOut() {
                            email = ""
                            emailCode = ""
                            recoveryCode = ""
                            displayName = ""
                            memberName = ""
                            page = .email
                        }
                    }
                }
            } message: {
                Text("Your household and shared history stay saved.")
            }
        }
        .font(RoomTheme.body())
        .foregroundStyle(RoomTheme.ink)
        .background(RoomTheme.paper)
        .buttonStyle(RoomButtonStyle())
        .textFieldStyle(RoomFieldStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-sheet")
        .tint(RoomTheme.sage)
        .presentationBackground(RoomTheme.paper)
        .presentationCornerRadius(16)
        .interactiveDismissDisabled(model.busy)
        .modifier(RoomSheetPresentation(idealHeight: contentHeight + headerHeight + 1))
        .onAppear {
            if model.signedIn { page = .account }
            memberName = model.state?.account?.name ?? ""
        }
        .onChange(of: model.signedIn) { _, signedIn in
            page = signedIn ? .account : .email
            if signedIn { memberName = model.state?.account?.name ?? "" }
        }
        .onChange(of: householdName) { creationID = UUID() }
        .onChange(of: memberName) { creationID = UUID() }
        .onChange(of: currency) { creationID = UUID() }
        .onChange(of: budget) { creationID = UUID() }
    }

    private var title: String {
        if model.deletionPending { return "Your account" }
        if model.signedIn {
            switch page {
            case .create: return "Create a household"
            case .join: return "Join a household"
            default: return "Your Roomlings account"
            }
        }
        switch page {
        case .verify: return "Verify your email"
        case .recover: return "Recover your account"
        default: return "Sign in to Roomlings"
        }
    }

    @ViewBuilder private var feedback: some View {
        if model.busy {
            AccountSection {
                HStack {
                    ProgressView()
                    Text("Contacting Roomlings...")
                }
                .accessibilityIdentifier("account-progress")
            }
        }
        if let message = model.message {
            AccountSection {
                Text(message)
                    .foregroundStyle(RoomTheme.error)
                    .accessibilityIdentifier("account-error")
                if model.state == nil && model.setupError == nil {
                    Button("Retry connection") { Task { await model.refresh() } }
                }
            }
            .padding(12)
            .background(RoomTheme.errorSoft, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.errorBorder))
        }
        if let notice = model.notice {
            AccountSection { Text(notice).accessibilityIdentifier("account-notice") }
        }
    }

    private var emailForm: some View {
        Group {
            AccountSection {
                emailField
                Button("Send sign-in code") {
                    Task {
                        if await model.sendCode(email: email) { page = .verify }
                    }
                }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Use the same account as the web app. No password needed.")
            }
            AccountSection {
                Button("Use a recovery code") {
                    model.clearFeedback()
                    page = .recover
                }
            }
        }
    }

    private var verifyForm: some View {
        Group {
            AccountSection("Email code") {
                Text(email)
                RoomField("Email sign-in code", text: $emailCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                RoomField("Display name", text: $displayName)
                    .textContentType(.nickname)
                RoomField("Device name", text: $deviceLabel)
                Button("Verify and sign in") {
                    Task {
                        if await model.verify(email: email, code: emailCode, name: displayName, label: deviceLabel) {
                            emailCode = ""
                            finishEntry()
                        }
                    }
                }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(emailCode.isEmpty || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceLabel.isEmpty)
            }
            AccountSection {
                Button("Send a new code") { Task { await model.sendCode(email: email) } }
                Button("Use a recovery code") {
                    model.clearFeedback()
                    page = .recover
                }
            }
        }
    }

    private var recoveryForm: some View {
        AccountSection {
            emailField
            RoomField("Account recovery code", text: $recoveryCode, secure: true)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            RoomField("Device name", text: $deviceLabel)
            Button("Recover my account") {
                Task {
                    if await model.recover(email: email, code: recoveryCode, label: deviceLabel) {
                        recoveryCode = ""
                        finishEntry()
                    }
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(email.isEmpty || recoveryCode.isEmpty || deviceLabel.isEmpty)
        } footer: {
            Text("Use one unused Roomlings account recovery code, not a kitchen invitation or an email code.")
        }
    }

    private var emailField: some View {
        RoomField("Email address", text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private var households: some View {
        Group {
            AccountSection("Signed in") {
                if let account = model.state?.account {
                    Text(account.name)
                    Text(account.email).foregroundStyle(RoomTheme.muted)
                }
            }
            AccountSection("Your households") {
                if let memberships = model.state?.memberships, !memberships.isEmpty {
                    ForEach(memberships, id: \.householdID) { membership in
                        Button {
                            Task {
                                if await model.select(id: membership.householdID) { dismiss() }
                            }
                        } label: {
                            HStack {
                                Text(membership.householdName)
                                Spacer()
                                if membership.householdID == model.state?.session?.household.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .accessibilityLabel("Open \(membership.householdName)")
                    }
                } else {
                    Text("No households yet.")
                    Text("If your home uses browser-only access, link it to this account on the web first.")
                        .foregroundStyle(RoomTheme.muted)
                }
                Button("Create a household") {
                    model.clearFeedback()
                    page = .create
                }
                Button("Join a household") {
                    model.clearFeedback()
                    page = .join
                }
            }
            accountActions
        }
    }

    private var accountActions: some View {
        AccountSection {
            Button("Refresh account") { Task { await model.refresh() } }
            Button("Sign out", role: .destructive) { confirmingSignOut = true }
        }
    }

    private var createForm: some View {
        AccountSection {
            RoomField("Household name", text: $householdName)
            RoomField("Your name in this household", text: $memberName)
            if controlAppearance == .roomlings {
                RoomPickerField("Currency", selectedLabel: currency.rawValue, selection: $currency) {
                    ForEach(currencies, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
            } else {
                Picker("Currency", selection: $currency) {
                    ForEach(currencies, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
                .accessibilityIdentifier("Currency")
            }
            RoomField("Monthly grocery budget", text: $budget)
                .keyboardType(.decimalPad)
            Button("Create household") {
                guard let cents = BudgetInput.cents(budget) else {
                    model.message = "Enter a budget from 0.01 to 1,000,000.00, with at most two decimal places."
                    return
                }
                Task {
                    if await model.create(name: householdName, memberName: memberName, currency: currency, budget: cents, requestID: creationID) {
                        dismiss()
                    }
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.isEmpty || budget.isEmpty)
        } footer: {
            Text("This creates a shared home in the same ledger as the web app. It does not move money.")
        }
    }

    private var joinForm: some View {
        AccountSection {
            RoomField("Invitation link or code", text: $invitation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            RoomField("Your name in this household", text: $memberName)
            Button("Join household") {
                Task {
                    if await model.join(code: invitation, memberName: memberName) { dismiss() }
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.isEmpty)
        }
    }

    private func finishEntry() {
        if model.state?.session != nil { dismiss() }
        else { page = .account }
    }
}

enum BudgetInput {
    static func cents(_ value: String) -> Int64? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !normalized.isEmpty else { return nil }
        let wholeText = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !wholeText.isEmpty || !fraction.isEmpty, fraction.count <= 2,
              wholeText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              fraction.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let whole = Int64(wholeText.isEmpty ? "0" : wholeText),
              whole <= 1_000_000,
              let remainder = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) else { return nil }
        let amount = whole * 100 + remainder
        return (1...100_000_000).contains(amount) ? amount : nil
    }
}
