import AppKit
import SwiftUI

/// The inbox window. Its controls are drawn by SwiftUI inside the content, not
/// as an NSToolbar: on macOS 26 and later a toolbar is drawn as glass, and the
/// compatibility key that opted out of that is gone in macOS 27.
@MainActor
final class InboxWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Karui"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)
        if !DemoMode.isActive { window.setFrameAutosaveName("KaruiInbox") }
        window.contentView = NSHostingView(rootView: InboxView(coordinator: coordinator))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        coordinator.inboxWindowAppeared()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.inboxWindowClosed()
    }
}
