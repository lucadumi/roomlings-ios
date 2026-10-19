import RoomlingsCore
import SwiftUI

struct AccountHouseholdMembersSection: View {
    @Bindable var model: AccountModel
    /// Shows the room admin roster, which the web keeps apart from household membership.
    var admins = false
    /// Shows the owner's invitations, as the web's household view does.
    var onInvite: (() -> Void)?
    @State private var confirmation: Confirmation?
    @State private var confirming = false

    private struct Confirmation {
        let accountID: UUID
        let householdID: UUID
        let version: Int64
        let action: Action

        enum Action {
            case transfer(HouseholdAccessMember), remove(HouseholdAccessMember), leave(String)
            case admin(HouseholdAccessMember, Bool)
        }

        var title: String {
            switch action {
            case .transfer: "Transfer household ownership?"
            case .remove: "Remove this roommate's access?"
            case .leave: "Leave this household?"
            case .admin(let member, let grant): grant ? "Make \(member.name) an admin?" : "Remove admin rights from \(member.name)?"
            }
        }

        var button: String {
            switch action {
            case .transfer: "Transfer ownership"
            case .remove: "Remove access"
            case .leave: "Leave household"
            case .admin(_, let grant): grant ? "Confirm admin access" : "Confirm removal of admin rights"
            }
        }

        var destructive: Bool {
            if case .admin(_, true) = action { return false }
            return true
        }

        var message: String {
            switch action {
            case .transfer(let member):
                "\(member.name) will manage household membership and invitations. You will remain a member and can still edit the ledger. Only the new owner can transfer ownership back."
            case .remove(let member):
                "\(member.name) will lose account, browser and recovery access to this household. Their shopping claims will be released. Their account, existing debts and financial records stay."
            case .admin(let member, true):
                "\(member.name) will be able to change room components and grant or revoke other admins. They will not gain the owner's invitation, removal or ownership powers."
            case .admin(let member, false):
                "\(member.name) will keep shared shopping, chores, ledger and daily room access, but will no longer be able to configure room components or manage admins."
            case .leave(let name):
                "You will lose access to \(name), including through old browser sessions and recovery codes. Your shopping claims will be released. Shared debts and history remain. If you are the only active roommate, new access will close."
            }
        }
    }

    var body: some View {
        // Mirrors the web household access view and room admin panel: a plain roster with text actions
        // (`src/Accounts.tsx`, `src/RoomAdminPanel.tsx`).
        VStack(alignment: .leading, spacing: 12) {
            if admins {
                heading("Room admins")
            } else {
                if let access = model.invitations { roommates(access) }
                HStack(spacing: 12) {
                    heading(model.invitations?.household.name ?? "Household members")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Task { await model.refresh(includeInvitations: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(RoomTheme.ink)
                            .frame(width: 44, height: 44)
                            .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh household members")
                    .accessibilityIdentifier("refresh-household-members")
                }
            }
            if let access = model.invitations {
                if admins {
                    hint("Owners and admins can add, remove and configure room components, and grant or remove admin rights. Everyone can use the shared shopping list, chores and daily room controls. Invitations, member removal and ownership transfers stay with the owner.")
                } else {
                    hint("You are \(roleDescription(access.role)). Owners and admins can configure rooms and manage admin rights. Only the owner manages invitations, removes roommates or transfers ownership. All active roommates can edit the shared ledger. Former roommates remain in financial history.")
                }
                if model.invitationNeedsRefresh {
                    RoomFeedback("Refresh household members before changing ownership or access.")
                }
                VStack(spacing: 0) {
                    ForEach(access.members) { member in row(member, access: access) }
                }
                if admins {
                    if access.role == .member { hint("Ask the owner or an admin if you need room editing access.") }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle().fill(RoomTheme.border).frame(height: 1).padding(.bottom, 8)
                        heading("Leave this household")
                        hint("Leaving removes access, not debts. Existing expenses, monthly bill schedules and repayments stay in the shared ledger. Review future bill participants with your roommates before leaving.")
                        if !access.canLeave {
                            hint("Transfer ownership to another active account-linked roommate before leaving this household.")
                        }
                        Button("Leave household") { present(.leave(access.household.name), access: access) }
                            .buttonStyle(RoomButtonStyle(kind: .text, size: 13))
                            .accessibilityLabel("Leave \(access.household.name)")
                            .accessibilityIdentifier("leave-household")
                            .disabled(!access.canLeave || model.invitationNeedsRefresh || !model.canUseAccount)
                    }
                    .padding(.top, 12)
                }
            } else {
                hint(admins ? "Load the current household members before managing admins."
                     : "Load the current household members before managing ownership.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(admins ? "household-admins" : "household-members")
        .confirmationDialog(confirmation?.title ?? "Confirm household change", isPresented: $confirming,
                            titleVisibility: .visible, presenting: confirmation) { confirmation in
            Button(confirmation.button, role: confirmation.destructive ? .destructive : nil) {
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
                    case .admin(let member, let grant):
                        await model.setRoomRole(member, admin: grant, householdID: confirmation.householdID,
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

    /// The web's roommate cards (`roommate-grid` in `src/App.tsx`): who shares the household and their grocery runs.
    private func roommates(_ access: HouseholdInvitationAccess) -> some View {
        let members = model.ledger?.members ?? []
        let active = members.filter { !$0.inactive }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WELCOME TO \(access.household.name.uppercased())")
                        .font(RoomTheme.body(10).weight(.semibold)).tracking(1.2).foregroundStyle(RoomTheme.muted)
                    Text("A seat at the table.").font(RoomTheme.heading(24)).foregroundStyle(RoomTheme.leaf)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(active) / 12")
                    .font(RoomTheme.body(11).weight(.medium)).foregroundStyle(RoomTheme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoomTheme.leafSoft, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(RoomTheme.border))
                    .accessibilityLabel("\(active) of 12 roommates")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)],
                      spacing: 12) {
                ForEach(members) { member in roommateCard(member, viewer: access.memberID) }
                if access.role == .owner, let onInvite {
                    Button(action: onInvite) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(RoomTheme.muted)
                                .frame(width: 48, height: 48)
                                .background(RoomTheme.leafSoft, in: Circle())
                            Text("One more?").font(RoomTheme.body(14).weight(.semibold)).foregroundStyle(RoomTheme.muted)
                                .padding(.top, 6)
                            Text("Invite a roommate").font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .background(RoomTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(RoomTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("invite-roommate")
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func roommateCard(_ member: HouseholdMember, viewer: UUID) -> some View {
        let runs = model.ledger?.expenses.filter { $0.bill == nil && $0.paidBy == member.id }.count ?? 0
        return VStack(spacing: 4) {
            Text(member.name.prefix(1).uppercased())
                .font(RoomTheme.body(17).weight(.semibold))
                .foregroundStyle(RoomTheme.primaryInk)
                .frame(width: 48, height: 48)
                .background(HouseholdMemberColor(hex: member.color).map(RoomTheme.member) ?? RoomTheme.sage, in: Circle())
                .overlay(Circle().strokeBorder(RoomTheme.paper, lineWidth: 3))
                .overlay(Circle().stroke(RoomTheme.border))
                .accessibilityHidden(true)
            Text(member.name).font(RoomTheme.body(14).weight(.semibold)).foregroundStyle(RoomTheme.muted)
                .multilineTextAlignment(.center).padding(.top, 9)
            Text(member.inactive ? "Former roommate" : member.id == viewer ? "That is you" : "Fellow fridge explorer")
                .font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted).multilineTextAlignment(.center)
            Rectangle().fill(RoomTheme.line).frame(height: 1).padding(.top, 16)
            Label("\(runs) grocery runs", systemImage: "receipt")
                .font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted).padding(.top, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 16)
        .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(RoomTheme.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("roommate-\(member.id.uuidString.lowercased())")
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(RoomTheme.body(21).weight(.medium)).foregroundStyle(RoomTheme.ink)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted).lineSpacing(4)
    }

    private func roleDescription(_ role: AccountRole) -> String {
        switch role {
        case .owner: "the owner"
        case .admin: "an admin"
        case .member: "a member"
        }
    }

    /// One roster row: the name and status, with any owner or admin actions as text buttons beside them.
    private func row(_ member: HouseholdAccessMember, access: HouseholdInvitationAccess) -> some View {
        let actions = WrappingRow(spacing: 16) { actionButtons(member, access: access) }
            .buttonStyle(RoomButtonStyle(kind: .text, size: 13))
        let details = VStack(alignment: .leading, spacing: 4) {
            Text(admins && member.id == access.memberID ? "\(member.name) (you)" : member.name)
                .font(RoomTheme.body(14).weight(.bold)).foregroundStyle(RoomTheme.leaf)
            Text(status(member)).font(RoomTheme.body(12)).foregroundStyle(RoomTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        return VStack(spacing: 0) {
            Rectangle().fill(RoomTheme.border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    details.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    details
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(admins ? "room-admin-member" : "household-member")-\(member.id.uuidString.lowercased())")
    }

    @ViewBuilder private func actionButtons(_ member: HouseholdAccessMember, access: HouseholdInvitationAccess) -> some View {
        let blocked = model.invitationNeedsRefresh || !model.canUseAccount
        if admins {
            if access.role != .member, member.active, member.role != .owner {
                let grant = member.role == .member
                Button(grant ? "Make admin" : "Remove admin rights") { present(.admin(member, grant), access: access) }
                    .accessibilityLabel(grant ? "Make \(member.name) an admin" : "Remove admin rights from \(member.name)")
                    .accessibilityIdentifier("room-admin-\(member.id.uuidString.lowercased())")
                    .disabled(blocked)
            }
        } else {
            if access.ownershipCandidates.contains(where: { $0.id == member.id }) {
                Button("Make owner") { present(.transfer(member), access: access) }
                    .accessibilityLabel("Make \(member.name) owner")
                    .accessibilityIdentifier("transfer-ownership-\(member.id.uuidString.lowercased())")
                    .disabled(blocked)
            }
            if access.removalCandidates.contains(where: { $0.id == member.id }) {
                Button("Remove access") { present(.remove(member), access: access) }
                    .accessibilityLabel("Remove access for \(member.name)")
                    .accessibilityIdentifier("remove-member-\(member.id.uuidString.lowercased())")
                    .disabled(blocked)
            }
        }
    }

    private func status(_ member: HouseholdAccessMember) -> String {
        guard member.active else { return "Former roommate" }
        let role: String
        switch member.role {
        case .owner: role = "Owner"
        case .admin: role = "Admin"
        case .member: role = "Member"
        }
        return admins ? role : "\(role); \(member.linked ? "account linked" : "browser access only")"
    }
}

/// Lays its views out in a row and wraps them onto new lines when the row is full, like the web's
/// wrapping text actions.
struct WrappingRow: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, width: proposal.width)
        let width = lines.map { line in line.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width,
                      height: lines.reduce(0) { $0 + ($1.map(\.height).max() ?? 0) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = line.map(\.height).max() ?? 0
            for size in line {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height
        }
    }

    private func lines(for subviews: Subviews, width: CGFloat?) -> [[CGSize]] {
        var lines: [[CGSize]] = []
        var current: [CGSize] = []
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : used + spacing + size.width
            if let width, !current.isEmpty, needed > width {
                lines.append(current)
                current = [size]
                used = size.width
            } else {
                current.append(size)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
