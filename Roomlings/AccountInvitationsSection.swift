import RoomlingsCore
import SwiftUI

struct AccountInvitationsSection: View {
    @Bindable var model: AccountModel
    @State private var revoking: HouseholdInvitation?
    @State private var confirmingRevocation = false

    var body: some View {
        AccountSection("Invitations") {
            if let access = model.invitations {
                Text(access.household.name).font(RoomTheme.body().weight(.semibold))
                if access.role == .owner {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ownerInvitations(access, at: context.date)
                    }
                    .confirmationDialog("Revoke this invitation?", isPresented: $confirmingRevocation,
                                        titleVisibility: .visible, presenting: revoking) { invitation in
                        Button("Revoke invitation", role: .destructive) {
                            Task {
                                await model.revokeInvitation(
                                    id: invitation.id, householdID: access.household.id, version: access.household.version
                                )
                            }
                        }
                    } message: { _ in
                        Text("This link will stop accepting new roommates. People who already joined keep their membership.")
                    }
                } else {
                    Text("Only the household owner can create or revoke invitations. Ask them to share a link.")
                        .foregroundStyle(RoomTheme.muted)
                }
            } else {
                Text("Load the current household invitations before sharing a new link.")
                    .foregroundStyle(RoomTheme.muted)
            }
            Button("Refresh invitations") { Task { await model.loadInvitations() } }
                .accessibilityIdentifier("refresh-invitations")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-invitations")
    }

    private func ownerInvitations(_ access: HouseholdInvitationAccess, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite a flatmate with a seven-day link. They will need to sign in to a Roomlings account.")
                .foregroundStyle(RoomTheme.muted)
            if let error = model.invitationSetupError {
                RoomFeedback(error)
            } else {
                Button("Create seven-day invitation") {
                    Task {
                        await model.createInvitation(householdID: access.household.id, version: access.household.version)
                    }
                }
                .accessibilityIdentifier("create-invitation")
                .disabled(model.invitationNeedsRefresh)
            }
            if model.canShareInvitation(at: date), let link = model.invitationLink {
                ShareLink(item: link, subject: Text("Join \(access.household.name)")) {
                    Label("Share invitation", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .accessibilityIdentifier("share-invitation")
                Text("Share this link now. For privacy, it is not saved on this device or shown again after you close Account.")
                    .font(RoomTheme.body(14))
                    .foregroundStyle(RoomTheme.muted)
            }
            if model.invitationOrigin?.origin.scheme == "http" {
                Text("This is a local preview link. Use your shared HTTPS deployment to invite another device.")
                    .font(RoomTheme.body(14))
                    .foregroundStyle(RoomTheme.muted)
            }
            if model.invitationNeedsRefresh {
                RoomFeedback("Refresh invitations before creating, sharing or revoking another link.")
            }
            let pending = access.invitations.filter { $0.isPending(at: date) }
            Text("Pending invitations").font(RoomTheme.body().weight(.semibold))
            if pending.isEmpty {
                Text("No pending invitations.").foregroundStyle(RoomTheme.muted)
            }
            ForEach(pending) { invitation in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Created \(invitation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(RoomTheme.muted)
                    Text("\(invitation.uses) accepted")
                        .foregroundStyle(RoomTheme.muted)
                    Button("Revoke", role: .destructive) {
                        revoking = invitation
                        confirmingRevocation = true
                    }
                    .accessibilityLabel("Revoke invitation \(invitation.id.uuidString.lowercased())")
                    .disabled(model.invitationNeedsRefresh)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("invitation-\(invitation.id.uuidString.lowercased())")
            }
        }
    }
}
