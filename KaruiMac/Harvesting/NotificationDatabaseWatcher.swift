import Foundation

/// Reads the database on a timer and reports each notification that wasn't there
/// the time before, and each that has gone. Polling, because the database is
/// written by a daemon in a protected folder; a file-event watcher is a later
/// improvement. The first pass reports what arrived while the app wasn't running,
/// up to a day back, as `backfilled`; anything older is left alone.
actor NotificationDatabaseWatcher {
    enum Event: Sendable {
        case appeared(NotificationRecord)
        /// Already there at launch, delivered within the last day.
        case backfilled(NotificationRecord)
        /// Cleared by the person or removed by its app: either way, seen.
        case disappeared(id: Int64)
    }

    static let backfillWindow: TimeInterval = 24 * 60 * 60

    private let database: NotificationDatabase
    private let bundleIdentifiers: Set<String>
    private let interval: Duration
    private var seen: Set<Int64>?

    init(database: NotificationDatabase, bundleIdentifiers: Set<String>, interval: Duration) {
        self.database = database
        self.bundleIdentifiers = bundleIdentifiers
        self.interval = interval
    }

    nonisolated func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<Event>.Continuation) async {
        while !Task.isCancelled {
            do {
                let records = try database.records(bundleIdentifiers: bundleIdentifiers)
                let current = Set(records.map(\.id))
                if let seen {
                    for record in records where !seen.contains(record.id) {
                        continuation.yield(.appeared(record))
                    }
                    for id in seen.subtracting(current) {
                        continuation.yield(.disappeared(id: id))
                    }
                } else {
                    let recent = records.filter { ($0.deliveredAt).map { Date().timeIntervalSince($0) <= Self.backfillWindow } ?? false }
                    SafeDiagnosticLog.shared.record("watcher: first pass, \(records.count) records from watched apps, \(recent.count) from the last day")
                    for record in recent.sorted(by: { ($0.deliveredAt ?? .distantPast) < ($1.deliveredAt ?? .distantPast) }) {
                        continuation.yield(.backfilled(record))
                    }
                }
                seen = current
            } catch {
                SafeDiagnosticLog.shared.record("watcher: read failed: \(error)")
            }
            try? await Task.sleep(for: interval)
        }
        continuation.finish()
    }
}
