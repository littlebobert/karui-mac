import Foundation

/// Reads the database on a timer and reports each notification that wasn't there
/// the time before. Polling, because the database is written by a daemon in a
/// protected folder; a file-event watcher is a later improvement. The records
/// already there at the first pass are not reported.
actor NotificationDatabaseWatcher {
    private let database: NotificationDatabase
    private let bundleIdentifiers: Set<String>
    private let interval: Duration
    private var seen: Set<Int64>?

    init(database: NotificationDatabase, bundleIdentifiers: Set<String>, interval: Duration) {
        self.database = database
        self.bundleIdentifiers = bundleIdentifiers
        self.interval = interval
    }

    nonisolated func appearances() -> AsyncStream<NotificationRecord> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<NotificationRecord>.Continuation) async {
        while !Task.isCancelled {
            do {
                let records = try database.records(bundleIdentifiers: bundleIdentifiers)
                if let seen {
                    for record in records where !seen.contains(record.id) {
                        continuation.yield(record)
                    }
                } else {
                    SafeDiagnosticLog.shared.record("watcher: first pass, \(records.count) records from watched apps")
                }
                seen = Set(records.map(\.id))
            } catch {
                SafeDiagnosticLog.shared.record("watcher: read failed: \(error)")
            }
            try? await Task.sleep(for: interval)
        }
        continuation.finish()
    }
}
