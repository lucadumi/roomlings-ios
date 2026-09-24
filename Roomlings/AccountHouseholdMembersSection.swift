import RoomlingsCore
import SwiftUI

struct AccountHouseholdMembersSection: View {
    @Bindable var model: AccountModel
    @State private var confirmation: Confirmation?
    @State private var confirming = false

    private struct Confirmation {
        let accountID: UUID
        let householdID: UUID
        let version: Int64
        let action: Action

        enum Action {
            case transfer(HouseholdAccessMember), remove(HouseholdAccessMember), leave(String)
        }

        var title: String {
            switch action {
            case .transfer: "Transfer household ownership?"
            case .remove: "Remove this roommate's access?"
            case .leave: "Leave this household?"
            }
        }

        var button: String {
            switch action {
            case .transfer: "Transfer ownership"
            case .remove: "Remove access"
            case .leave: "Leave household"
            }
        }

        var message: String {
            switch action {
            case .transfer(let member):
                "\(member.name) will manage household membership and invitations. You will remain a member and can still edit the ledger. Only the new owner can transfer ownership back."
            case .remove(let member):
                "\(member.name) will lose account, browser and recovery access to this household. Their shopping claims will be released. Their account, existing debts and financial records stay."
            case .leave(let name):
                "You will lose access to \(name), including through old browser sessions and recovery codes. Your shopping claims will be released. Shared debts and history remain. If you are the only active roommate, new access will close."
            }
        }
    }

    var body: some View {
        AccountSection {
            if let access = model.invitations {
                Text(access.household.name).font(RoomTheme.heading(20))
                Text("The owner manages household membership and invitations. All active roommates can edit the shared ledger.")
                    .foregroundStyle(RoomTheme.muted)
                if model.invitationNeedsRefresh {
                    RoomFeedback("Refresh household members before changing ownership or access.")
                }
                ForEach(access.members) { member in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.name).font(RoomTheme.body().weight(.semibold))
                        Text(status(member)).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                        if access.ownershipCandidates.contains(where: { $0.id == member.id }) {
                            Button("Make owner") {
                                present(.transfer(member), access: access)
                            }
                            .accessibilityLabel("Make \(member.name) owner")
                            .accessibilityIdentifier("transfer-ownership-\(member.id.uuidString.lowercased())")
                            .disabled(model.invitationNeedsRefresh || !model.canUseAccount)
                        }
                        if access.removalCandidates.contains(where: { $0.id == member.id }) {
                            Button("Remove access", role: .destructive) {
                                present(.remove(member), access: access)
                            }
                            .accessibilityLabel("Remove access for \(member.name)")
                            .accessibilityIdentifier("remove-member-\(member.id.uuidString.lowercased())")
                            .disabled(model.invitationNeedsRefresh || !model.canUseAccount)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("household-member-\(member.id.uuidString.lowercased())")
                }
                if access.role != .owner {
                    Text("Only the current owner can transfer ownership.").foregroundStyle(RoomTheme.muted)
                } else if access.ownershipCandidates.isEmpty {
                    Text("Another active roommate must join with a Roomlings account before they can become owner.")
                        .foregroundStyle(RoomTheme.muted)
                }
                AccountSection("Leave household") {
                    Text("Leaving removes access, not debts. Review future bill participants with your roommates before leaving.")
                        .foregroundStyle(RoomTheme.muted)
                    if !access.canLeave {
                        Text("Transfer ownership to another active account-linked roommate before leaving this household.")
                            .foregroundStyle(RoomTheme.muted)
                    }
                    Button("Leave household", role: .destructive) { present(.leave(access.household.name), access: access) }
                        .accessibilityLabel("Leave \(access.household.name)")
                        .accessibilityIdentifier("leave-household")
                        .disabled(!access.canLeave || model.invitationNeedsRefresh || !model.canUseAccount)
                }
            } else {
                Text("Load the current household members before managing ownership.").foregroundStyle(RoomTheme.muted)
            }
            Button("Refresh household members") { Task { await model.refresh(includeInvitations: true) } }
                .accessibilityIdentifier("refresh-household-members")
        }
        .disabled(model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("household-members")
        .confirmationDialog(confirmation?.title ?? "Confirm household change", isPresented: $confirming,
                            titleVisibility: .visible, presenting: confirmation) { confirmation in
            Button(confirmation.button, role: .destructive) {
                Task {
                    switch confirmation.action {
                    case .transfer(let member):
                        await model.transferOwnership(
                            to: member.id, householdID: confirmation.householdID,
                            version: confirmation.version, accountID: confirmation.accountID
                        )
                    case .remove(let member):
                        await model.removeHouseholdMember(
                            id: member.id, householdID: confirmation.householdID,
                            version: confirmation.version, accountID: confirmation.accountID
                        )
                    case .leave:
                        await model.leaveHousehold(householdID: confirmation.householdID,
                                                   version: confirmation.version, accountID: confirmation.accountID)
                    }
                }
            }
            Button("Cancel", role: .cancel, action: dismissConfirmation)
        } message: { confirmation in
            Text(confirmation.message)
        }
        .onChange(of: model.state?.account?.id) { _, _ in dismissConfirmation() }
        .onChange(of: model.state?.session?.household.id) { _, _ in dismissConfirmation() }
        .onChange(of: model.state?.session?.household.version) { _, _ in dismissConfirmation() }
        .onChange(of: model.invitationNeedsRefresh) { _, needsRefresh in
            if needsRefresh { dismissConfirmation() }
        }
    }

    private func dismissConfirmation() {
        confirming = false
        confirmation = nil
    }

    private func present(_ action: Confirmation.Action, access: HouseholdInvitationAccess) {
        guard let accountID = model.state?.account?.id else {
            model.message = "Sign in again before managing household access."
            return
        }
        confirmation = Confirmation(accountID: accountID, householdID: access.household.id,
                                    version: access.household.version, action: action)
        confirming = true
    }

    private func status(_ member: HouseholdAccessMember) -> String {
        guard member.active else { return "Former roommate" }
        let role: String
        switch member.role {
        case .owner: role = "Owner"
        case .admin: role = "Admin"
        case .member: role = "Member"
        }
        return "\(role); \(member.linked ? "account linked" : "browser access only")"
    }
}
