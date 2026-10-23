import RoomlingsCore
import SwiftUI

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.roomControlAppearance) private var controlAppearance
    @Environment(NativeNotifications.self) private var notifications
    @Bindable var model: AccountModel
    @State private var page = Page.email
    @State private var scrollTarget: String?
    @State private var email = ""
    @State private var emailCode = ""
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
    @State private var deletionConfirmation = ""

    private enum Page { case email, verify, recover, account, create, join, deleteAccount, reauthenticate, householdMembers, householdAdmins, houseRules, roomStyle, profile, devices, recoveryCodes }
    @State private var invitation = ""
    @State private var houseRules = AccountHouseRulesSection.Form()
    @State private var roomStyle = AccountRoomStyleSection.Form()
    @State private var profileName = ""
    @State private var profileDevice = ""
    @State private var reauthenticatingForRecovery = false
    private let currencies: [HouseholdCurrency] = [.eur, .usd, .gbp, .ron]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        feedback
                        incomingInvitation
                        incomingNotification
                        accountContent
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(model.busy)
            .modifier(RoomSheetLoading(model: model, label: "Loading your account...",
                                       refreshOnOpen: model.message == nil, includeInvitations: true))
            .confirmationDialog("Sign out on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        if await model.signOut() { resetAfterSignOut() }
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
            if model.signedIn { page = model.pendingInvitation == nil ? .account : .join }
            invitation = model.pendingInvitation?.value ?? ""
            memberName = model.state?.account?.name ?? ""
        }
        .onDisappear {
            model.clearInvitationLink()
            model.forgetRecoveryCodes()
        }
        .onChange(of: page) { _, page in
            // New recovery codes are shown once and never survive leaving their page.
            if page != .recoveryCodes { model.forgetRecoveryCodes() }
        }
        .onChange(of: model.signedIn) { _, signedIn in
            page = signedIn ? (model.pendingInvitation == nil ? .account : .join) : .email
            if signedIn { memberName = model.state?.account?.name ?? "" }
        }
        .onChange(of: model.state?.account?.id) { _, _ in
            deletionConfirmation = ""
            emailCode = ""
            if model.accountDeletionConfirmed {
                email = ""
                recoveryCode = ""
                memberName = ""
                householdName = ""
                invitation = ""
            }
            if [.deleteAccount, .reauthenticate, .householdMembers, .householdAdmins, .houseRules, .roomStyle, .profile, .devices, .recoveryCodes].contains(page) {
                page = .account
            }
        }
        .onChange(of: model.state?.session?.household.id) { _, _ in
            if [.householdMembers, .householdAdmins, .houseRules, .roomStyle].contains(page) { page = .account }
        }
        .onChange(of: model.pendingInvitation) { _, pending in
            invitation = pending?.value ?? ""
            if pending != nil, model.canUseAccount, page != .deleteAccount, page != .reauthenticate { page = .join }
        }
        .onChange(of: model.incomingInvitationError) { _, error in
            if error != nil { invitation = "" }
        }
        .onChange(of: householdName) { creationID = UUID() }
        .onChange(of: memberName) { creationID = UUID() }
        .onChange(of: currency) { creationID = UUID() }
        .onChange(of: budget) { creationID = UUID() }
    }

    @ViewBuilder private var accountContent: some View {
        if let setupError = model.setupError {
            AccountSection { Text(setupError) }
        } else if model.deletionCleanupRequired || model.deletionNeedsRefresh || model.deletionPending {
            deletionRecovery
        } else if model.membershipNeedsRefresh {
            AccountSection("Check household access") {
                Text("The leave request may have reached the server. Household actions stay closed until you refresh your account.")
                Button("Refresh account") { Task { await model.refresh(includeInvitations: true) } }
                    .accessibilityIdentifier("refresh-membership-access")
            }
        } else if model.signedIn {
            signedInContent
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

    @ViewBuilder private var signedInContent: some View {
        switch page {
        case .create: createForm
        case .join: joinForm
        case .householdMembers:
            AccountHouseholdMembersSection(model: model, onInvite: { scrollTarget = "member-invitations" })
            if model.invitations?.role == .owner {
                AccountInvitationsSection(model: model).id("member-invitations")
            }
            Button("Back to account") { page = .account }
                .buttonStyle(RoomButtonStyle(kind: .text))
        case .householdAdmins:
            AccountHouseholdMembersSection(model: model, admins: true)
            Button("Back to account") { page = .account }
                .buttonStyle(RoomButtonStyle(kind: .text))
        case .profile:
            AccountProfileSection(model: model, name: $profileName, deviceLabel: $profileDevice)
            backToAccount
        case .devices:
            AccountDevicesSection(model: model) { resetAfterSignOut() }
            backToAccount
        case .recoveryCodes:
            AccountRecoveryCodesSection(model: model) {
                model.clearFeedback()
                emailCode = ""
                reauthenticatingForRecovery = true
                page = .reauthenticate
            }
            if model.recoveryCodes == nil { backToAccount }
        case .roomStyle:
            AccountRoomStyleSection(model: model, form: $roomStyle) { page = .account }
            Button("Back to account") {
                model.clearFeedback()
                page = .account
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .disabled(model.busy)
        case .houseRules:
            AccountHouseRulesSection(model: model, form: $houseRules) { page = .account }
            Button("Back to account") {
                model.clearFeedback()
                page = .account
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
            .disabled(model.busy)
        case .deleteAccount:
            if let account = model.state?.account { deletionForm(account) }
        case .reauthenticate:
            if let account = model.state?.account,
               let device = model.state?.devices.first(where: \.current) {
                reauthenticationForm(account, device: device)
            }
        default: households
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                RoomBrandMark(size: 36)
                heading.fixedSize()
                Spacer(minLength: 4)
                dismissButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    RoomBrandMark(size: 36)
                    Spacer(minLength: 0)
                    dismissButton
                }
                heading.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heading: some View {
        Text(title)
            .font(RoomTheme.heading())
            .accessibilityAddTraits(.isHeader)
    }

    private var dismissButton: some View {
        Button { dismiss() } label: {
            Text(model.signedIn ? "Done" : "Not now")
                .frame(minWidth: 44)
        }
        .buttonStyle(RoomButtonStyle(kind: .text))
        .fixedSize()
        .disabled(model.busy)
    }

    private var title: String {
        if model.deletionCleanupRequired { return "Clear saved access" }
        if model.deletionNeedsRefresh { return "Check account deletion" }
        if model.deletionPending { return "Account deletion pending" }
        if model.membershipNeedsRefresh { return "Check household access" }
        if model.signedIn {
            switch page {
            case .create: return "Create a household"
            case .join: return "Join a household"
            case .deleteAccount: return "Delete your account"
            case .reauthenticate: return "Verify your email"
            case .householdMembers: return "Who shares this household?"
            case .householdAdmins: return "Household admins"
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
                    RoomBrandMark()
                    Text("Contacting Roomlings...")
                }
                .accessibilityIdentifier("account-progress")
            }
        }
        if let message = model.message ?? model.viewerFailure {
            RoomFeedback(message, identifier: "account-error") {
                if model.state == nil && model.setupError == nil {
                    Button("Retry connection") { Task { await model.refresh() } }
                        .buttonStyle(RoomButtonStyle(kind: .secondary))
                }
            }
        }
        if let notice = model.notice {
            AccountSection { Text(notice).accessibilityIdentifier("account-notice") }
        }
    }

    @ViewBuilder private var incomingInvitation: some View {
        if !model.deletionPending && !model.deletionNeedsRefresh && !model.deletionCleanupRequired,
           model.pendingInvitation != nil || model.incomingInvitationError != nil {
            AccountSection("Household invitation") {
                if let error = model.incomingInvitationError {
                    RoomFeedback(error, identifier: "invitation-link-error")
                } else {
                    Text(model.signedIn
                         ? "Review your invitation and name before joining. Your existing households stay saved."
                         : "Sign in to use your invitation. You will review it before joining.")
                        .accessibilityIdentifier("pending-invitation")
                }
                Button("Cancel invitation") {
                    model.dismissInvitation()
                    model.clearFeedback()
                    invitation = ""
                    page = model.signedIn ? .account : .email
                }
            }
        }
    }

    @ViewBuilder private var incomingNotification: some View {
        if notifications.pending != nil && !model.deletionPending && !model.deletionNeedsRefresh && !model.deletionCleanupRequired {
            AccountSection("Notification") {
                Text(model.signedIn
                     ? "Your notification is waiting. Finish here, then close Account to open it."
                     : "Sign in to open your notification. Your household access will be checked first.")
                    .accessibilityIdentifier("pending-notification")
                if model.signedIn {
                    Button("Open notification") { dismiss() }
                        .accessibilityIdentifier("open-pending-notification")
                }
                Button("Dismiss notification") { notifications.cancelPending() }
                    .buttonStyle(RoomButtonStyle(kind: .text))
            }
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
                Button("Verify and sign in") {
                    Task {
                        if await model.verify(email: email, code: emailCode, label: deviceLabel) {
                            emailCode = ""
                            finishEntry()
                        }
                    }
                }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(emailCode.isEmpty)
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
                    Button("Edit profile") {
                        model.clearFeedback()
                        profileName = account.name
                        profileDevice = model.state?.devices.first(where: \.current)?.label ?? ""
                        page = .profile
                    }
                    .accessibilityIdentifier("open-profile")
                    Button("Account sessions") {
                        model.clearFeedback()
                        page = .devices
                    }
                    .accessibilityIdentifier("open-devices")
                    Button("Recovery codes") {
                        Task { if await model.loadRecoveryStatus() { page = .recoveryCodes } }
                    }
                    .accessibilityIdentifier("open-recovery-codes")
                }
            }
            AccountSection("Your households") {
                if let memberships = model.state?.memberships, !memberships.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(memberships, id: \.householdID) { membership in householdRow(membership) }
                    }
                } else {
                    Text("No households yet.")
                    Text("Link a browser-only home on the web first.")
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
            if let householdID = model.state?.session?.household.id {
                AccountSection {
                    Button("House rules") {
                        model.clearFeedback()
                        houseRules = AccountHouseRulesSection.Form()
                        page = .houseRules
                    }
                    .accessibilityIdentifier("open-house-rules")
                    Button("Room style") {
                        model.clearFeedback()
                        roomStyle = AccountRoomStyleSection.Form()
                        page = .roomStyle
                    }
                    .accessibilityIdentifier("open-room-style")
                    Button("Household admins") {
                        Task {
                            if await model.loadHouseholdAccess() { page = .householdAdmins }
                        }
                    }
                    .accessibilityIdentifier("manage-household-admins")
                }
                AccountInvitationsSection(model: model)
                    .id(householdID)
                AccountNotificationsSection(model: model)
                    .id("notifications-\(householdID)")
            }
            accountActions
            AccountSection("Account lifecycle") {
                Text("Hand over shared households first. Ledger history stays.")
                    .foregroundStyle(RoomTheme.muted)
                Button("Delete my account", role: .destructive) {
                    model.clearFeedback()
                    deletionConfirmation = ""
                    page = .deleteAccount
                }
                .accessibilityIdentifier("open-account-deletion")
            }
        }
    }

    /// One of your households as the web lists it: name and role, Open, and Membership for the open
    /// household, whose members this session can load.
    private func householdRow(_ membership: AccountMembership) -> some View {
        let current = membership.householdID == model.state?.session?.household.id
        let role = switch membership.role {
        case .owner: "Owner"
        case .admin: "Admin"
        case .member: "Member"
        }
        let details = VStack(alignment: .leading, spacing: 4) {
            Text(membership.householdName).font(RoomTheme.body(14).weight(.bold)).foregroundStyle(RoomTheme.leaf)
            Text(role).font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        let actions = HStack(spacing: 16) {
            Button("Open") {
                Task {
                    if await model.select(id: membership.householdID) { dismiss() }
                }
            }
            .buttonStyle(RoomButtonStyle(size: 13))
            .fixedSize()
            .accessibilityLabel("Open \(membership.householdName)")
            if current {
                Button("Membership") {
                    Task {
                        if await model.loadHouseholdAccess() { page = .householdMembers }
                    }
                }
                .buttonStyle(RoomButtonStyle(kind: .text, size: 13))
                .accessibilityLabel("Manage \(membership.householdName)")
                .accessibilityIdentifier("manage-household-members")
            }
        }
        return VStack(spacing: 0) {
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    details.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    details
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
        }
    }

    private func deletionForm(_ account: Account) -> some View {
        AccountSection("This cannot be undone") {
            Text("This deletes your account and sign-in identity and revokes linked access. Shared ledger records keep former-roommate references so balances remain correct. Names written in expense descriptions are not automatically removed. Export any ledgers you need first.")
                .foregroundStyle(RoomTheme.muted)
            Text("Enter \(account.email) to confirm.")
            if model.state?.memberships.contains(where: { $0.role == .owner }) == true {
                Button("Manage household ownership") {
                    deletionConfirmation = ""
                    page = .account
                }
                .accessibilityIdentifier("manage-ownership-before-deletion")
            }
            RoomField("Account email to confirm deletion", text: $deletionConfirmation)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("account-deletion-email")
            Text("Deletion requires a sign-in within the last ten minutes.")
                .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            Button("Verify email again") {
                model.clearFeedback()
                emailCode = ""
                deletionConfirmation = ""
                reauthenticatingForRecovery = false
                page = .reauthenticate
            }
            .accessibilityIdentifier("reauthenticate-account")
            Button("Delete my account", role: .destructive) {
                Task {
                    if await model.deleteAccount(accountID: account.id, confirmation: deletionConfirmation) {
                        deletionConfirmation = ""
                        page = .email
                    }
                }
            }
            .accessibilityIdentifier("confirm-account-deletion")
            .disabled(deletionConfirmation != account.email || model.deletionRequiresReauthentication || notifications.busy)
            Button("Cancel") {
                deletionConfirmation = ""
                model.clearFeedback()
                page = .account
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion-form")
    }

    private func reauthenticationForm(_ account: Account, device: AccountDevice) -> some View {
        AccountSection(reauthenticatingForRecovery ? "Verify before changing recovery codes" : "Verify before deleting") {
            Text(account.email)
            Text(reauthenticatingForRecovery
                 ? "Verification only refreshes your sign-in. Your recovery codes stay unchanged until you replace or revoke them."
                 : "Verification only refreshes your sign-in. You will review and confirm deletion again afterwards.")
                .foregroundStyle(RoomTheme.muted)
            Button("Send verification code") { Task { await model.sendCode(email: account.email) } }
                .accessibilityIdentifier("send-deletion-verification")
            RoomField("Email sign-in code", text: $emailCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Verify email") {
                Task {
                    let forRecovery = reauthenticatingForRecovery
                    if await model.reauthenticate(accountID: account.id, code: emailCode, label: device.label,
                                                  forRecovery: forRecovery) {
                        emailCode = ""
                        deletionConfirmation = ""
                        reauthenticatingForRecovery = false
                        page = forRecovery ? .recoveryCodes : .deleteAccount
                    }
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .accessibilityIdentifier("verify-deletion-email")
            .disabled(emailCode.isEmpty)
            Button("Cancel") {
                emailCode = ""
                model.clearFeedback()
                page = reauthenticatingForRecovery ? .recoveryCodes : .account
                reauthenticatingForRecovery = false
            }
            .buttonStyle(RoomButtonStyle(kind: .text))
        }
    }

    @ViewBuilder private var deletionRecovery: some View {
        if model.deletionCleanupRequired {
            AccountSection("Finish clearing this device") {
                Text("Your account was deleted. Saved access on this device still needs to be cleared before you continue.")
                Button("Clear saved access") { Task { await model.finishAccountDeletionCleanup() } }
                    .accessibilityIdentifier("clear-deleted-account-access")
                Button("Refresh account") { Task { await model.refresh() } }
            }
        } else if model.deletionPending {
            AccountSection("Deletion is not complete yet") {
                Text("Account access is disabled while deletion finishes. The server retries automatically. This is not a completed deletion yet.")
                Button("Check deletion status") { Task { await model.refresh() } }
                    .accessibilityIdentifier("check-account-deletion")
                if let account = model.state?.account {
                    Button("Retry account deletion", role: .destructive) {
                        Task { await model.deleteAccount(accountID: account.id, confirmation: account.email) }
                    }
                    .accessibilityIdentifier("retry-account-deletion")
                    .disabled(notifications.busy)
                }
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
            }
        } else {
            AccountSection("Deletion could not be confirmed") {
                Text("The request may have reached the server. Household access stays closed until you check its status.")
                Button("Check deletion status") { Task { await model.refresh() } }
                    .accessibilityIdentifier("check-account-deletion")
            }
        }
    }

    private var accountActions: some View {
        AccountSection {
            Button("Refresh account") { Task { await model.refresh(includeInvitations: true) } }
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
            Text("A shared home for chores, shopping and money.")
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
                    if await model.join(code: invitation, memberName: memberName), model.pendingInvitation == nil { dismiss() }
                }
            }
            .buttonStyle(RoomButtonStyle(kind: .primary))
            .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.isEmpty)
        }
    }

    private var backToAccount: some View {
        Button("Back to account") {
            model.clearFeedback()
            page = .account
        }
        .buttonStyle(RoomButtonStyle(kind: .text))
        .disabled(model.busy)
    }

    private func resetAfterSignOut() {
        email = ""
        emailCode = ""
        recoveryCode = ""
        memberName = ""
        page = .email
    }

    private func finishEntry() {
        if model.pendingInvitation != nil {
            invitation = model.pendingInvitation?.value ?? ""
            page = .join
        } else if model.state?.session != nil { dismiss() }
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
