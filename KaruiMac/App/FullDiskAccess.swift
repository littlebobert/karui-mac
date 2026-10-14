import AppKit
import Observation

/// Whether this app may read Notification Center's database, which macOS keeps
/// behind Full Disk Access. There is no API to ask for it: the person turns the app
/// on in System Settings, and the app finds out by trying to read.
@MainActor
@Observable
final class FullDiskAccess {
    private(set) var isGranted = false
    /// Whether System Settings was opened from here, after which a relaunch is offered:
    /// macOS doesn't always apply the change to a running app.
    private(set) var hasOpenedSystemSettings = false
    private let probe: URL

    /// Messages' database, also behind Full Disk Access, probed in case a macOS
    /// release lists apps whose reads it refused. macOS 27 doesn't: tccd answers
    /// "Denied (Service Policy)" and stores nothing, so the person adds the app with
    /// the pane's + button. The read is harmless either way.
    private static let registrationProbe = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Messages/chat.db")

    init(probe: URL = NotificationDatabase.standard.url) {
        self.probe = probe
    }

    func refresh() {
        isGranted = Self.canRead(probe)
        if !isGranted {
            // Only for the side effect of appearing in the list.
            _ = Self.canRead(Self.registrationProbe)
        }
    }

    func openSystemSettings() {
        hasOpenedSystemSettings = true
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// For the pane's + button, or dragging the app into the list.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            SafeDiagnosticLog.shared.record("relaunch failed: \(error.localizedDescription)")
        }
    }

    private static func canRead(_ url: URL) -> Bool {
        // EPERM without access; ENOENT on a Mac that has never had the file.
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
