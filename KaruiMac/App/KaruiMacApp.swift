import SwiftUI

@main
struct KaruiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var settings = appDelegate.coordinator.settings

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("About Karui")) {
                    appDelegate.coordinator.showAbout()
                }
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.string("Check for Updates…")) {
                    appDelegate.coordinator.autoUpdates.checkForUpdates()
                }
                .disabled(!appDelegate.coordinator.autoUpdates.canCheckForUpdates)
            }
            CommandMenu(L10n.string("Notifications")) {
                let coordinator = appDelegate.coordinator
                let selection = coordinator.inbox.selection
                Group {
                    Button(L10n.string("Mark as Read")) { coordinator.markRead(selection) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!coordinator.inbox.selectedItems.contains(where: \.isUnread))
                    Button(L10n.string("Mark as Important")) { coordinator.setCategory("notifyNow", selection) }
                        .keyboardShortcut("1", modifiers: .command)
                        .disabled(coordinator.inbox.allHaveCategory("notifyNow", ids: selection))
                    Button(L10n.string("Mark as Neutral")) { coordinator.setCategory("summary", selection) }
                        .keyboardShortcut("2", modifiers: .command)
                        .disabled(coordinator.inbox.allHaveCategory("summary", ids: selection))
                    Button(L10n.string("Mark as Spam")) { coordinator.setCategory("silence", selection) }
                        .keyboardShortcut("3", modifiers: .command)
                        .disabled(coordinator.inbox.allHaveCategory("silence", ids: selection))
                    Divider()
                    Button(L10n.string("Delete")) { coordinator.delete(selection) }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
                .disabled(selection.isEmpty)
                Divider()
                Button(L10n.string("Sync Now")) { coordinator.syncNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // No help book: the Help menu points at the site and the bug report.
            CommandGroup(replacing: .help) {
                Link(L10n.string("Karui for Mac Help"), destination: URL(string: "https://karui.jp/mac")!)
                Button(L10n.string("Report a Bug…")) { _ = BugReport.compose() }
            }
        }

        MenuBarExtra(isInserted: $settings.showsMenuBarItem) {
            MenuBarMenu(coordinator: appDelegate.coordinator)
        } label: {
            let unread = settings.showsUnreadBadge ? appDelegate.coordinator.inbox.unreadCount : 0
            Image(systemName: unread > 0 ? "tray.full.fill" : "tray.fill")
            if unread > 0 { Text(String(unread)) }
        }
    }
}
