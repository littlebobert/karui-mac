import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }
        // A second copy, such as the installed app opened from the Dock while a
        // development build runs: the two share the inbox's store and settings but
        // each keeps its own inbox in memory, so their unread counts drift apart, and
        // each would harvest and sync on its own. This one hands over and quits. The
        // demo runs beside the real app on purpose, with its own settings and no store.
        if !DemoMode.isActive, let running = Self.otherRunningCopy() {
            SafeDiagnosticLog.shared.record("app: another copy is running, quitting")
            // Opening the running copy, rather than activating it, shows its inbox
            // even when its window is closed, as a click on its Dock icon would.
            if let url = running.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                running.activate()
            }
            NSApp.terminate(nil)
            return
        }
        coordinator.start()
    }

    private static func otherRunningCopy() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != current && !$0.isTerminated }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        coordinator.handleRemoteNotification(userInfo)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        SafeDiagnosticLog.shared.record("pushes: registration failed: \(error.localizedDescription)")
    }

    /// Closing the window leaves the app harvesting; it keeps going until Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.showInbox()
        return true
    }
}
