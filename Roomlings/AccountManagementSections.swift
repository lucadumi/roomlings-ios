import RoomlingsCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccountProfileSection: View {
    @Bindable var model: AccountModel
    @Binding var name: String
    @Binding var deviceLabel: String

    var body: some View {
        AccountSection("Profile") {
            RoomField("Your account name", text: $name)
            Button("Save name") { Task { _ = await model.updateProfile(name: name) } }
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || name == model.state?.account?.name)
                .accessibilityIdentifier("save-account-name")
            RoomField("This device's name", text: $deviceLabel)
            Button("Save device name") { Task { _ = await model.renameDevice(label: deviceLabel) } }
                .buttonStyle(RoomButtonStyle(kind: .secondary))
                .disabled(model.busy || deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || deviceLabel == model.state?.devices.first(where: \.current)?.label)
                .accessibilityIdentifier("save-device-name")
        } footer: {
            Text("Your account name does not rename you in existing household ledgers.")
        }
    }
}

struct AccountDevicesSection: View {
    @Bindable var model: AccountModel
    let onSignedOut: () -> Void
    @State private var revoking: AccountDevice?
    @State private var confirmingAll = false

    var body: some View {
        AccountSection("Account sessions") {
            ForEach(model.state?.devices ?? []) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.label).font(RoomTheme.body().weight(.semibold))
                        if device.current {
                            Text("This device").font(RoomTheme.body(13)).foregroundStyle(RoomTheme.muted)
                        }
                    }
                    Text("Last active: \(Self.date(device.lastUsedAt))").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    Text("Expires: \(Self.date(device.expiresAt))").font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                    if !device.current {
                        Button("Sign out") { revoking = device }
                            .buttonStyle(RoomButtonStyle(kind: .secondary))
                            .accessibilityLabel("Revoke \(device.label)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("device-\(device.id.uuidString.lowercased())")
            }
            Button("Sign out all devices", role: .destructive) { confirmingAll = true }
                .buttonStyle(RoomButtonStyle(kind: .text))
                .accessibilityIdentifier("sign-out-all-devices")
        }
        .disabled(model.busy)
        .confirmationDialog("Sign out that account session?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }
        ), titleVisibility: .visible, presenting: revoking) { device in
            Button("Revoke session", role: .destructive) { Task { _ = await model.revokeDevice(device) } }
        } message: { device in
            Text("This signs out \(device.label). It does not remove household membership or change the ledger.")
        }
        .confirmationDialog("Sign out every device?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Sign out all devices", role: .destructive) {
                Task { if await model.signOutEverywhere() { onSignedOut() } }
            }
        } message: {
            Text("This revokes all account sessions and browser sessions for linked identities. Unused account recovery codes and browser recovery codes remain valid until replaced or revoked. Your ledger and memberships stay.")
        }
    }

    static func date(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        guard let date = parser.date(from: timestamp) ?? fallback.date(from: timestamp) else { return timestamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct AccountRecoveryCodesSection: View {
    @Bindable var model: AccountModel
    let onVerify: () -> Void
    @State private var confirmingReplace = false
    @State private var confirmingRevoke = false
    @State private var copied = false

    var body: some View {
        Group {
            if let result = model.recoveryCodes {
                AccountSection("Your account recovery codes") {
                    Text("Save these codes in your password manager or another private place. Each code signs in to your account once, without an email code. Anyone with a code and your email can access your account.")
                        .foregroundStyle(RoomTheme.muted)
                    Text("This is the only time these codes are shown. They are not saved on this device and cannot be displayed again after you leave this screen.")
                        .font(RoomTheme.body().weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.codes, id: \.self) { code in
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recovery-code-list")
                    Button(copied ? "Recovery codes copied" : "Copy all recovery codes") { copy(result.codes) }
                        .buttonStyle(RoomButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("copy-recovery-codes")
                    Button("I saved these codes") {
                        model.forgetRecoveryCodes()
                        copied = false
                        model.notice = "Recovery codes ready. Keep your copy private."
                    }
                    .buttonStyle(RoomButtonStyle(kind: .primary))
                    .accessibilityIdentifier("saved-recovery-codes")
                } footer: {
                    Text("Copied codes are kept on this device's clipboard for two minutes and are not shared with other devices.")
                }
            } else if let status = model.recoveryStatus {
                AccountSection("\(status.remaining) unused recovery \(status.remaining == 1 ? "code" : "codes")") {
                    Text("Account recovery codes are a backup when email sign-in is unavailable. They restore your existing account and memberships, without creating another roommate or signing out your other devices.")
                        .foregroundStyle(RoomTheme.muted)
                    Text("Generate \(AccountRecoveryStatus.codeCount) single-use codes and keep them somewhere private. You may need to verify your email again before changing them.")
                        .foregroundStyle(RoomTheme.muted)
                    if let updatedAt = status.updatedAt {
                        Text("Last changed: \(AccountDevicesSection.date(updatedAt))").foregroundStyle(RoomTheme.muted)
                    }
                    if model.recoveryRequiresReauthentication {
                        Button("Verify your email") { onVerify() }
                            .buttonStyle(RoomButtonStyle(kind: .primary))
                            .accessibilityIdentifier("verify-for-recovery")
                    } else if model.recoveryNeedsRefresh {
                        Button("Refresh recovery code status") { Task { await model.loadRecoveryStatus() } }
                            .buttonStyle(RoomButtonStyle(kind: .primary))
                            .accessibilityIdentifier("refresh-recovery-status")
                    } else {
                        Button(status.remaining > 0 ? "Replace recovery codes" : "Generate recovery codes") {
                            if status.remaining > 0 { confirmingReplace = true }
                            else { Task { _ = await model.generateRecoveryCodes(version: status.version) } }
                        }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .accessibilityIdentifier("generate-recovery-codes")
                        if status.remaining > 0 {
                            Button("Revoke recovery codes") { confirmingRevoke = true }
                                .buttonStyle(RoomButtonStyle(kind: .text))
                                .accessibilityIdentifier("revoke-recovery-codes")
                        }
                    }
                }
                .confirmationDialog("Replace your account recovery codes?", isPresented: $confirmingReplace, titleVisibility: .visible) {
                    Button("Replace recovery codes", role: .destructive) {
                        Task { _ = await model.generateRecoveryCodes(version: status.version) }
                    }
                } message: {
                    Text("All older unused codes will stop working. Save the new set when it appears. Existing sessions and household memberships stay unchanged.")
                }
                .confirmationDialog("Revoke your unused recovery codes?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
                    Button("Revoke recovery codes", role: .destructive) {
                        Task { _ = await model.revokeRecoveryCodes(version: status.version) }
                    }
                } message: {
                    Text("These codes will no longer sign in to your account. Email sign-in and existing sessions stay available. Your households and memberships are unchanged.")
                }
            } else {
                AccountSection("Recovery codes") {
                    Text("Recovery code status has not loaded yet.")
                    Button("Load recovery code status") { Task { await model.loadRecoveryStatus() } }
                        .accessibilityIdentifier("refresh-recovery-status")
                }
            }
        }
        .disabled(model.busy)
    }

    private func copy(_ codes: [String]) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: codes.joined(separator: "\n")]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        copied = true
    }
}
