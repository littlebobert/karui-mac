import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator
    /// Nil while checking.
    @State private var isShortcutInstalled: Bool?

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

    private func iPhoneDescription(sendsNotifications: Bool, sortsHere: Bool) -> String {
        guard sendsNotifications else {
            return L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. The notification's text never leaves this Mac.")
        }
        return sortsHere
            ? L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. When your iPhone hasn't sorted a notification after two minutes, this Mac sends it with its own verdict, end-to-end encrypted, so it shows in your iPhone's History and alerts you if it's Important. This needs Show History on your Mac turned on in Karui on your iPhone.")
            : L10n.string("Each link goes to your iPhone through your iCloud account, with a fingerprint of the notification. When your iPhone hasn't sorted a notification after two minutes, its text goes too, end-to-end encrypted, so Karui on your iPhone can sort it and alert you if it's Important. This needs Show History on your Mac turned on in Karui on your iPhone.")
    }

    private func checkShortcut() async {
        let name = coordinator.settings.secondOpinionShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        isShortcutInstalled = name.isEmpty ? false : await MacSecondOpinion.isInstalled(name: name)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10n.string("General"), systemImage: "gearshape") }
            iPhoneTab
                .tabItem { Label(L10n.string("iPhone"), systemImage: "iphone") }
            sortingTab
                .tabItem { Label(L10n.string("Sorting"), systemImage: "line.3.horizontal.decrease.circle") }
            fullDiskAccessTab
                .tabItem { Label(L10n.string("Full Disk Access"), systemImage: "lock.shield") }
        }
        .onAppear {
            coordinator.loginItem.refresh()
            coordinator.fullDiskAccess.refresh()
            coordinator.refreshSyncStatus()
        }
    }

    private var generalTab: some View {
        @Bindable var settings = coordinator.settings
        return Form {
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
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var iPhoneTab: some View {
        @Bindable var settings = coordinator.settings
        return Form {
            Section {
                Text(coordinator.syncStatus.description)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.string("Send notifications only this Mac got to your iPhone"), isOn: $settings.asksIPhoneToSort)
                Text(iPhoneDescription(sendsNotifications: settings.asksIPhoneToSort, sortsHere: settings.sortsOnThisMac && coordinator.canSortHere))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sortingTab: some View {
        @Bindable var settings = coordinator.settings
        return Form {
            Section {
                Toggle(L10n.string("Sort notifications on this Mac"), isOn: $settings.sortsOnThisMac)
                Text(sortingStatus)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.string("Second Opinion")) {
                TextField(L10n.string("Second Opinion Shortcut"), text: $settings.secondOpinionShortcutName)
                LabeledContent(L10n.string("Shortcut")) {
                    switch isShortcutInstalled {
                    case true?: Text(L10n.string("Installed"))
                    case false?:
                        Button(L10n.string("Get the Shortcut")) {
                            NSWorkspace.shared.open(MacSecondOpinion.shortcutURL)
                        }
                    case nil: ProgressView().controlSize(.small)
                    }
                }
                Text(L10n.string("When Second Opinion is on in Karui on your iPhone, this Mac asks Apple’s Private Cloud Compute through this Shortcut, with the same prompt your iPhone sends. The Shortcut takes text and returns what Use Model, set to Private Cloud Compute, answers."))
                    .foregroundStyle(.secondary)
            }
            if let policy = coordinator.sortingSettings.policy {
                IPhoneSortingSettingsSection(policy: policy, updatedAt: coordinator.sortingSettings.updatedAt)
            }
        }
        .formStyle(.grouped)
        // The iPhone's settings can run long; the tab scrolls past this.
        .frame(width: Self.width, height: 560)
        .task { await coordinator.sortingSettings.refresh() }
        // Again on each change of name, and when the person comes back from Shortcuts.
        .task(id: settings.secondOpinionShortcutName) { await checkShortcut() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkShortcut() }
        }
    }

    private var fullDiskAccessTab: some View {
        Form {
            Section {
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
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let width: CGFloat = 480
}
