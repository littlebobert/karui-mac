import Foundation

/// The Focus that's on, read from macOS's own Focus files in ~/Library/DoNotDisturb/DB,
/// which needs the Full Disk Access Karui has already. Karui's Focus filter would say
/// so itself (`MacFocusFilter`), but on macOS 27 the Focus service can't run a
/// Developer ID app's filter: "Unable to create ApplicationService connection:
/// Operation not permitted". These files are what scripts and tools have read since
/// macOS 12; they're undocumented, so they're read defensively, and a file that can't
/// be read or doesn't parse means no Focus.
struct ActiveFocus: Equatable, Sendable {
    let identifier: String
    let name: String?
    /// Bundle IDs of the apps this Focus lets through.
    let allowedApps: Set<String>
}

enum MacFocusFiles {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/DoNotDisturb/DB", directoryHint: .isDirectory)

    static func activeFocus(now: Date = Date(), calendar: Calendar = .current, in directory: URL = directory) -> ActiveFocus? {
        let configurations = try? Data(contentsOf: directory.appending(path: "ModeConfigurations.json"))
        let identifier = (try? Data(contentsOf: directory.appending(path: "Assertions.json"))).flatMap(activeModeIdentifier(assertions:))
            ?? configurations.flatMap { scheduledModeIdentifier(configurations: $0, now: now, calendar: calendar) }
        guard let identifier else { return nil }
        let secure = try? Data(contentsOf: directory.appending(path: "ModeConfigurationsSecure.json"))
        return ActiveFocus(
            identifier: identifier,
            name: configurations.flatMap { name(of: identifier, configurations: $0) },
            allowedApps: secure.map { allowedApps(of: identifier, secure: $0) } ?? []
        )
    }

    /// Whether any Focus lets this app through, or nil when the files can't be read.
    static func anyFocusAllows(_ bundleID: String, in directory: URL = directory) -> Bool? {
        guard let data = try? Data(contentsOf: directory.appending(path: "ModeConfigurationsSecure.json")),
              let modes = secureModes(data) else { return nil }
        return modes.keys.contains { allowedApps(of: $0, secure: data).contains(bundleID) }
    }

    // MARK: The files

    /// The Focus turned on, by hand or from another device: the newest of the
    /// assertions, since one device's can outlast another's.
    static func activeModeIdentifier(assertions: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: assertions) as? [String: Any],
              let records = (root["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]] else { return nil }
        return records
            .max { ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0) }
            .flatMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }
    }

    /// A Focus on by its schedule, which can be on without an assertion. A schedule
    /// trigger is on when `enabledSetting` is 2; `timePeriodWeekdays` is taken to have
    /// Sunday as its lowest bit (127, every day, is the only value seen); a period
    /// that ends before it starts runs overnight.
    static func scheduledModeIdentifier(configurations: Data, now: Date, calendar: Calendar) -> String? {
        guard let modes = modeConfigurations(configurations) else { return nil }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekdayBit = 1 << ((parts.weekday ?? 1) - 1)
        for (identifier, mode) in modes.sorted(by: { $0.key < $1.key }) {
            let triggers = (mode["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]] ?? []
            for trigger in triggers where trigger["class"] as? String == "DNDModeConfigurationScheduleTrigger" && trigger["enabledSetting"] as? Int == 2 {
                guard let startHour = trigger["timePeriodStartTimeHour"] as? Int, let endHour = trigger["timePeriodEndTimeHour"] as? Int else { continue }
                let start = startHour * 60 + (trigger["timePeriodStartTimeMinute"] as? Int ?? 0)
                let end = endHour * 60 + (trigger["timePeriodEndTimeMinute"] as? Int ?? 0)
                let weekdays = trigger["timePeriodWeekdays"] as? Int ?? 127
                // Overnight, the part after midnight belongs to the day it started.
                let isAfterMidnight = start > end && minute < end
                let dayBit = isAfterMidnight ? (weekdayBit == 1 ? 1 << 6 : weekdayBit >> 1) : weekdayBit
                guard weekdays & dayBit != 0 else { continue }
                let isOn = start < end ? (minute >= start && minute < end) : start > end && (minute >= start || minute < end)
                if isOn { return identifier }
            }
        }
        return nil
    }

    static func name(of identifier: String, configurations: Data) -> String? {
        (modeConfigurations(configurations)?[identifier]?["mode"] as? [String: Any])?["name"] as? String
    }

    static func allowedApps(of identifier: String, secure: Data) -> Set<String> {
        let configuration = secureModes(secure)?[identifier]?["secureConfiguration"] as? [String: Any]
        return Set((configuration?["allowedApplications"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    private static func modeConfigurations(_ data: Data) -> [String: [String: Any]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: [String: Any]]
    }

    private static func secureModes(_ data: Data) -> [String: [String: Any]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["data"] as? [[String: Any]])?.first?["secureModeConfigurations"] as? [String: [String: Any]]
    }
}

/// Watches the Focus files' folder: macOS replaces a file whole when the Focus changes,
/// which shows as a change to the folder.
@MainActor
final class MacFocusWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var last: ActiveFocus?
    private var hasRead = false
    var changed: (ActiveFocus?) -> Void = { _ in }

    func start() {
        guard source == nil else { return }
        let descriptor = open(MacFocusFiles.directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            SafeDiagnosticLog.shared.record("focus: can't watch the Focus files (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        check()
    }

    private func check() {
        let focus = MacFocusFiles.activeFocus()
        guard !hasRead || focus?.identifier != last?.identifier else { return }
        hasRead = true
        last = focus
        SafeDiagnosticLog.shared.record(focus.map { "focus: on, lets Karui through: \($0.allowedApps.contains(Bundle.main.bundleIdentifier ?? "") ? "yes" : "no")" } ?? "focus: off")
        changed(focus)
    }
}
