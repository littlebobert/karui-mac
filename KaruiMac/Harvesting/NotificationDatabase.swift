import Foundation

/// One notification as Notification Center's database has it.
struct NotificationRecord: Equatable, Sendable {
    let id: Int64
    /// Lowercased.
    let bundleIdentifier: String
    let deliveredAt: Date?
    let title: String?
    let subtitle: String?
    let body: String?
    /// The app's own identifier for the notification (`req.iden`).
    let identifier: String?
    /// The string values of the app's user info (`req.usda`).
    let userInfo: [String: String]
}

/// Notification Center's database. Reading it needs Full Disk Access. Each read
/// works from a copy, so it never contends with the daemon's writes, and decodes
/// only the apps asked for: other apps' text is never looked at.
struct NotificationDatabase: Sendable {
    static let standard = NotificationDatabase(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.usernoted/db2/db")
    )

    let url: URL

    func records(bundleIdentifiers: Set<String>) throws -> [NotificationRecord] {
        let snapshot = try DatabaseSnapshot(of: url)
        defer { snapshot.remove() }
        let database = try SQLiteDatabase(readingFrom: snapshot.url)
        let rows = try database.rows("""
            select record.rec_id, record.delivered_date, record.data, app.identifier
            from record left join app using (app_id)
            """)
        return rows.compactMap { row in
            guard let id = row[0].integer,
                  let bundleIdentifier = row[3].text?.lowercased(),
                  bundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }
            let payload = row[2].blob.flatMap(NotificationPayload.init(data:))
            return NotificationRecord(
                id: id,
                bundleIdentifier: bundleIdentifier,
                deliveredAt: row[1].real.map(Date.init(timeIntervalSinceReferenceDate:)),
                title: payload?.title,
                subtitle: payload?.subtitle,
                body: payload?.body,
                identifier: payload?.identifier,
                userInfo: payload?.userInfo ?? [:]
            )
        }
    }
}

/// The request inside a record's `data` column: a plain binary plist whose `req`
/// dictionary has four-letter keys. See Experiments/FINDINGS.md.
struct NotificationPayload {
    var title: String?
    var subtitle: String?
    var body: String?
    var identifier: String?
    var userInfo: [String: String]

    init?(data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["$archiver"] == nil,
              let request = plist["req"] as? [String: Any] else {
            return nil
        }
        title = request["titl"] as? String
        subtitle = request["subt"] as? String
        body = request["body"] as? String
        identifier = request["iden"] as? String
        userInfo = (request["usda"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }
}

/// A copy of a database with its write-ahead log, in a folder this process can
/// write in, which a read-only connection needs.
struct DatabaseSnapshot {
    let url: URL
    private let folder: URL

    init(of database: URL) throws {
        let manager = FileManager.default
        folder = manager.temporaryDirectory.appending(path: "karui-snapshot-\(UUID().uuidString)")
        url = folder.appending(path: "db")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(filePath: database.path + suffix)
                guard manager.fileExists(atPath: source.path) else { continue }
                try manager.copyItem(at: source, to: URL(filePath: url.path + suffix))
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
