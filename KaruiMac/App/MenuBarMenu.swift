import SwiftUI

struct MenuBarMenu: View {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.string("Open Karui")) {
            coordinator.showInbox()
            openWindow(id: InboxWindow.id)
        }
        SettingsLink {
            Text(L10n.string("Settings…"))
        }
        Divider()
        Button(L10n.string("Quit Karui")) {
            NSApp.terminate(nil)
        }
    }
}
