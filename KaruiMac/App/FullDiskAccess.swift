import AppKit
import Observation

/// Whether this app may read Notification Center's database, which macOS keeps
/// behind Full Disk Access. There is no API to ask for it: the person turns the app
/// on in System Settings, and the app finds out by trying to read.
@MainActor
@Observable
final class FullDiskAccess {
    private(set) var isGranted = false
    /// Notification Center's database isn't there: macOS makes a new one with the
    /// next notification (it went missing on a Mac that ran out of disk space). Not
    /// a permissions problem, and the app keeps checking for it.
    private(set) var isDatabaseMissing = false
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
        let result = Self.probe(probe)
        let granted = result == .readable
        let missing = result == .missing
        if granted != isGranted || missing != isDatabaseMissing {
            SafeDiagnosticLog.shared.record("full disk access: \(result)")
        }
        isGranted = granted
        isDatabaseMissing = missing
        if result == .denied {
            // Only for the side effect of appearing in the list.
            _ = Self.probe(Self.registrationProbe)
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

    enum Probe: Equatable, CustomStringConvertible {
        case readable, denied, missing
        case failed(Int32)

        var description: String {
            switch self {
            case .readable: "readable"
            case .denied: "denied"
            case .missing: "database missing"
            case .failed(let code): "open failed, errno \(code) (\(String(cString: strerror(code))))"
            }
        }
    }

    /// EPERM or EACCES without access; ENOENT when the file isn't there.
    private static func probe(_ url: URL) -> Probe {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            switch errno {
            case EPERM, EACCES: return .denied
            case ENOENT: return .missing
            default: return .failed(errno)
            }
        }
        close(descriptor)
        return .readable
    }
}
