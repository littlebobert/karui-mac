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
        }

        MenuBarExtra("Karui", systemImage: "bell.badge", isInserted: $settings.showsMenuBarItem) {
            MenuBarMenu(coordinator: appDelegate.coordinator)
        }
    }
}
