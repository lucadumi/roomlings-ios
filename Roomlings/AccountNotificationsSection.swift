import RoomlingsCore
import SwiftUI

struct AccountNotificationsSection: View {
    @Bindable var model: AccountModel
    @Environment(NativeNotifications.self) private var notifications

    var body: some View {
        AccountSection("Notifications") {
            if let settings = notifications.settings,
               settings.householdID == model.state?.session?.household.id {
                RoomSwitch("Daily chore reminders", isOn: Binding(
                    get: { settings.preferences.chores },
                    set: { value in
                        Task {
                            await notifications.savePreferences(NotificationPreferences(chores: value, money: settings.preferences.money))
                        }
                    }
                ))
                .accessibilityIdentifier("notification-chores")
                Text("One summary of your assigned due chores at 09:00 in the household's time zone.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                RoomSwitch("Expense and repayment updates", isOn: Binding(
                    get: { settings.preferences.money },
                    set: { value in
                        Task {
                            await notifications.savePreferences(NotificationPreferences(chores: settings.preferences.chores, money: value))
                        }
                    }
                ))
                .accessibilityIdentifier("notification-money")
                Text("Sent when another roommate records an expense or repayment. Notification text never includes names or amounts.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                Text("These household preferences are saved to your membership, including after reinstalling the app.")
                    .font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
                if !settings.pushAvailable {
                    Text("Push delivery is not configured on this server yet.")
                        .foregroundStyle(RoomTheme.muted)
                        .accessibilityIdentifier("push-unavailable")
                }
                if notifications.enabledOnDevice && notifications.permission == .allowed {
                    Text(notifications.registered ? "Notifications are enabled on this device."
                         : notifications.waitingForAPNs ? "Waiting for Apple notification registration..."
                         : "This device is not connected for notifications yet.")
                        .accessibilityIdentifier("notification-device-status")
                    Button("Disable on this device") { Task { await notifications.disable() } }
                        .accessibilityIdentifier("disable-notifications")
                } else {
                    Button("Enable notifications") { Task { await notifications.enable() } }
                        .buttonStyle(RoomButtonStyle(kind: .primary))
                        .accessibilityIdentifier("enable-notifications")
                        .disabled(!settings.pushAvailable)
                }
                if notifications.permission == .denied {
                    Button("Open notification settings") { Task { await notifications.openSystemSettings() } }
                        .accessibilityIdentifier("notification-system-settings")
                }
            } else if notifications.busy {
                HStack {
                    RoomBrandMark()
                    Text("Loading notification preferences...")
                }
            } else {
                Text("Load your household's notification preferences before enabling notifications.")
                    .foregroundStyle(RoomTheme.muted)
            }
            if let error = notifications.error {
                RoomFeedback(error, identifier: "notifications-error") {
                    Button("Retry notifications") { Task { await notifications.retry() } }
                        .buttonStyle(RoomFeedbackActionStyle())
                }
            }
            Button("Refresh notifications") { Task { await notifications.refreshSettings() } }
                .buttonStyle(RoomButtonStyle(kind: .text))
                .accessibilityIdentifier("refresh-notifications")
        }
        .disabled(notifications.busy || model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-notifications")
        .task {
            notifications.attach(to: model)
            await notifications.refreshSettings()
        }
    }
}
