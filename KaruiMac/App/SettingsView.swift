import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var settings = coordinator.settings

        Form {
            Section {
                Toggle(L10n.string("Show in menu bar"), isOn: $settings.showsMenuBarItem)
                Toggle(L10n.string("Show in Dock"), isOn: $settings.showsDockIcon)
                Toggle(L10n.string("Badge with unread count"), isOn: $settings.showsUnreadBadge)
                Toggle(
                    L10n.string("Start at login"),
                    isOn: Binding(
                        get: { coordinator.loginItem.isEnabled },
                        set: { coordinator.loginItem.setEnabled($0) }
                    )
                )
            }
            Section(L10n.string("iPhone")) {
                Text(coordinator.syncStatus.description)
                    .foregroundStyle(.secondary)
                Text(L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. The notification's text never leaves this Mac."))
                    .foregroundStyle(.secondary)
            }
            Section(L10n.string("Full Disk Access")) {
                LabeledContent(
                    L10n.string("Status"),
                    value: coordinator.fullDiskAccess.isGranted ? L10n.string("On") : L10n.string("Off")
                )
                Text(L10n.string("Karui reads Notification Center's database to find where each notification opens. macOS keeps that database behind Full Disk Access."))
                    .foregroundStyle(.secondary)
                Button(L10n.string("Open System Settings")) {
                    coordinator.fullDiskAccess.openSystemSettings()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            coordinator.loginItem.refresh()
            coordinator.fullDiskAccess.refresh()
            coordinator.refreshSyncStatus()
        }
    }
}
