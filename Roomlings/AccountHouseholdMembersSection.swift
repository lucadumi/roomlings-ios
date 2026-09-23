import RoomlingsCore
import SwiftUI

struct AccountHouseholdMembersSection: View {
    @Bindable var model: AccountModel
    @State private var transfer: Transfer?
    @State private var confirming = false

    private struct Transfer {
        let accountID: UUID
        let householdID: UUID
        let version: Int64
        let member: HouseholdAccessMember
    }

    var body: some View {
        AccountSection {
            if let access = model.invitations {
                Text(access.household.name).font(RoomTheme.heading(20))
                Text("The owner manages household membership and invitations. All active roommates can edit the shared ledger.")
                    .foregroundStyle(RoomTheme.muted)
                if model.invitationNeedsRefresh {
                    RoomFeedback("Refresh household members before making another ownership change.")
                }
                ForEach(access.members) { member in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.name).font(RoomTheme.body().weight(.semibold))
                        Text(status(member)).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                        if access.ownershipCandidates.contains(where: { $0.id == member.id }) {
                            Button("Make owner") {
                                guard let accountID = model.state?.account?.id else {
                                    model.message = "Sign in again before managing household ownership."
                                    return
                                }
                                transfer = Transfer(accountID: accountID, householdID: access.household.id,
                                                    version: access.household.version, member: member)
                                confirming = true
                            }
                            .accessibilityLabel("Make \(member.name) owner")
                            .accessibilityIdentifier("transfer-ownership-\(member.id.uuidString.lowercased())")
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
            } else {
                Text("Load the current household members before managing ownership.").foregroundStyle(RoomTheme.muted)
            }
            Button("Refresh household members") { Task { await model.loadHouseholdAccess() } }
                .accessibilityIdentifier("refresh-household-members")
        }
        .disabled(model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("household-members")
        .confirmationDialog("Transfer household ownership?", isPresented: $confirming,
                            titleVisibility: .visible, presenting: transfer) { transfer in
            Button("Transfer ownership", role: .destructive) {
                Task {
                    await model.transferOwnership(
                        to: transfer.member.id, householdID: transfer.householdID,
                        version: transfer.version, accountID: transfer.accountID
                    )
                }
            }
            Button("Cancel", role: .cancel, action: dismissConfirmation)
        } message: { transfer in
            Text("\(transfer.member.name) will manage household membership and invitations. You will remain a member and can still edit the ledger. Only the new owner can transfer ownership back.")
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
        transfer = nil
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
