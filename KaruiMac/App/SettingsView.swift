import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator

    private var sortingStatus: String {
        guard #available(macOS 26.0, *) else {
            return L10n.string("Needs macOS 26 or later, with Apple Intelligence turned on.")
        }
        guard coordinator.sortingSettings.policy != nil else {
            return L10n.string("Waiting for your iPhone’s settings. In Karui on your iPhone, turn on Show History on your Mac.")
        }
        guard let updatedAt = coordinator.sortingSettings.updatedAt else {
            return L10n.string("Sorts each notification as it arrives, with your iPhone’s settings. Nothing leaves this Mac for it.")
        }
        return L10n.format(
            "Sorts each notification as it arrives, with your iPhone’s settings from %@. Nothing leaves this Mac for it.",
            updatedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

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
                Toggle(L10n.string("Have your iPhone sort notifications only this Mac got"), isOn: $settings.asksIPhoneToSort)
                Text(settings.asksIPhoneToSort
                    ? L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. When your iPhone hasn't sorted a notification after two minutes, its text goes too, end-to-end encrypted, so Karui on your iPhone can sort it and alert you if it's Important. This needs Show History on your Mac turned on in Karui on your iPhone.")
                    : L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. The notification's text never leaves this Mac."))
                    .foregroundStyle(.secondary)
            }
            Section(L10n.string("Sorting on this Mac")) {
                Toggle(L10n.string("Sort notifications on this Mac"), isOn: $settings.sortsOnThisMac)
                Text(sortingStatus)
                    .foregroundStyle(.secondary)
                TextField(L10n.string("Second Opinion Shortcut"), text: $settings.secondOpinionShortcutName)
                Text(L10n.string("When Second Opinion is on in Karui on your iPhone, this Mac asks Apple’s Private Cloud Compute through this Shortcut, with the same prompt your iPhone sends. The Shortcut takes text and returns what Use Model, set to Private Cloud Compute, answers."))
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
        .task { await coordinator.sortingSettings.refresh() }
        .frame(width: 460)
        .onAppear {
            coordinator.loginItem.refresh()
            coordinator.fullDiskAccess.refresh()
            coordinator.refreshSyncStatus()
        }
    }
}
