import SwiftUI

@main
struct KaruiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var settings = appDelegate.coordinator.settings

        Window("Karui", id: InboxWindow.id) {
            InboxView(coordinator: appDelegate.coordinator)
        }
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.string("Check for Updates…")) {
                    appDelegate.coordinator.autoUpdates.checkForUpdates()
                }
                .disabled(!appDelegate.coordinator.autoUpdates.canCheckForUpdates)
            }
            CommandGroup(replacing: .help) {
                // App names, counts, and failures; never notification text.
                Button(L10n.string("Copy Diagnostics")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SafeDiagnosticLog.shared.recentText(), forType: .string)
                }
            }
        }

        MenuBarExtra("Karui", systemImage: "bell.badge", isInserted: $settings.showsMenuBarItem) {
            MenuBarMenu(coordinator: appDelegate.coordinator)
        }

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
    }
}
