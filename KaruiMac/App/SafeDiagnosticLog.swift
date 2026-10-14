import Foundation
import OSLog

/// In-memory events for a bug report, mirrored to the system log so `log show`
/// can read them (subsystem com.justin.henry.karui.mac, category Diagnostics).
/// Nothing recorded here may be notification text: app names, counts, and what
/// failed are fine, which is why the mirror is public.
final class SafeDiagnosticLog: @unchecked Sendable {
    static let shared = SafeDiagnosticLog()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.justin.henry.karui.mac", category: "Diagnostics")
    private var entries: [Entry] = []

    private struct Entry {
        let date: Date
        let event: String
        var repetitionCount: Int
    }

    private init() {}

    func record(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        lock.lock()
        if entries.last?.event == event {
            entries[entries.count - 1].repetitionCount += 1
        } else {
            entries.append(Entry(date: Date(), event: event, repetitionCount: 1))
            entries = Array(entries.suffix(1000))
        }
        lock.unlock()
    }

    /// The newest events that fit in `maxCharacters`, oldest first, so a bug-report
    /// email stays a reasonable size. Notes how many older events were left out.
    func recentText(maxCharacters: Int = 40_000) -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        var characterCount = 0
        for entry in snapshot.reversed() {
            let repetition = entry.repetitionCount > 1 ? " repeated=\(entry.repetitionCount)" : ""
            let line = "\(formatter.string(from: entry.date)) \(entry.event)\(repetition)"
            guard characterCount + line.count + 1 <= maxCharacters else { break }
            lines.append(line)
            characterCount += line.count + 1
        }
        let omitted = snapshot.count - lines.count
        if omitted > 0 {
            lines.append("(\(omitted) earlier events omitted to keep this report short)")
        }
        return lines.reversed().joined(separator: "\n")
    }
}
