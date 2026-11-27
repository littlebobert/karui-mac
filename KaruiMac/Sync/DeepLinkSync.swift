import CloudKit
import Foundation
import KaruiLinkKit
import KaruiSorting

/// Sends each link to the iPhone through the person's own iCloud: one record per
/// notification in the private database of Karui's container, named by the
/// fingerprint so the iPhone fetches it directly and a repeat overwrites. The URL
/// is stored encrypted; the text is never stored. Records are deleted when they
/// expire, from a list kept here, so no query (and no index) is needed.
actor DeepLinkSync {
    static let containerIdentifier = "iCloud.com.justin.henry.karui"

    enum Status: Equatable, Sendable {
        case unknown
        case available
        case noAccount
        case restricted
        case unavailable(String)

        var isAvailable: Bool { self == .available }
    }

    /// Nil in a build that lacks the entitlement, which can't use iCloud at all.
    private let container: CKContainer?
    private var database: CKDatabase? { container?.privateCloudDatabase }
    private let expiryStore: ExpiryStore
    private(set) var status: Status = .unknown
    /// The records as the server returned them, so a read can update one in place.
    private var savedRecords: [String: CKRecord] = [:]

    init(container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil) {
        self.container = container
        expiryStore = ExpiryStore()
    }

    @discardableResult
    func refreshStatus() async -> Status {
        guard let container else {
            status = .unavailable("This build can't use iCloud, so links stay on this Mac")
            return status
        }
        do {
            switch try await container.accountStatus() {
            case .available: status = .available
            case .noAccount: status = .noAccount
            case .restricted: status = .restricted
            case .couldNotDetermine, .temporarilyUnavailable: status = .unavailable("iCloud is temporarily unavailable")
            @unknown default: status = .unavailable("iCloud status is unknown")
            }
        } catch {
            status = .unavailable(error.localizedDescription)
        }
        return status
    }

    /// Sends the link; the record on iCloud, after. A link sent before (by this Mac
    /// before a relaunch, or by another Mac) is left as it is, read mark included,
    /// and comes back so the caller can see whether it's already read. The record of
    /// an earlier notification with the same text is another matter: this one takes
    /// it over, unread (`isEarlierNotification`).
    @discardableResult
    func send(_ link: DeepLinkRecord) async -> DeepLinkRecord? {
        if !status.isAvailable {
            await refreshStatus()
        }
        guard status.isAvailable, let database else {
            SafeDiagnosticLog.shared.record("sync: skipped, iCloud \(status)")
            return nil
        }
        let record = CKRecord(
            recordType: DeepLinkRecordSchema.recordType,
            recordID: CKRecord.ID(recordName: link.fingerprint)
        )
        Self.fill(record, with: link)
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            var saved: CKRecord
            var replacedEarlier = false
            do {
                saved = try results.saveResults[record.recordID]?.get() ?? record
            } catch let error as CKError where error.code == .serverRecordChanged {
                guard let serverRecord = error.serverRecord else { throw error }
                if Self.isEarlierNotification(serverRecord, than: link) {
                    saved = try await replace(serverRecord, with: link, in: database)
                    replacedEarlier = true
                } else {
                    // Already there; the server's copy is the truth, read mark and all.
                    saved = serverRecord
                }
            }
            savedRecords[link.fingerprint] = saved
            expiryStore.remember(recordName: link.fingerprint, expiresAt: link.expiresAt)
            var sent = link
            sent.readAt = saved[DeepLinkRecordSchema.readAt] as? Date
            SafeDiagnosticLog.shared.record(
                "sync: sent \(link.app) link\(replacedEarlier ? ", in place of an earlier one with the same text" : "")\(sent.readAt == nil ? "" : ", already read")"
            )
            return sent
        } catch {
            SafeDiagnosticLog.shared.record("sync: send failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The link's fields on a record. Whatever read mark the record had goes: it was
    /// for the notification the record was about before.
    static func fill(_ record: CKRecord, with link: DeepLinkRecord) {
        record[DeepLinkRecordSchema.fingerprint] = link.fingerprint
        record[DeepLinkRecordSchema.app] = link.app
        record.encryptedValues[DeepLinkRecordSchema.url] = link.url.absoluteString
        record[DeepLinkRecordSchema.opensExactContent] = link.opensExactContent ? 1 : 0
        record[DeepLinkRecordSchema.deliveredAt] = link.deliveredAt
        record[DeepLinkRecordSchema.expiresAt] = link.expiresAt
        record[DeepLinkRecordSchema.readAt] = nil
    }

    /// Whether the record already on iCloud is for an earlier notification with the
    /// same text, as a second "Verify your email" from one sender is: the fingerprint
    /// is the app and the text, with no time in it, so both are one record. Taken as
    /// this notification's, its read mark made the new one read on arrival: nothing
    /// watched for it being read here, and the iPhone's alert stayed (2026-11-27).
    /// The same notification reaching another Mac a little later is not that.
    static func isEarlierNotification(_ serverRecord: CKRecord, than link: DeepLinkRecord) -> Bool {
        guard let deliveredAt = serverRecord[DeepLinkRecordSchema.deliveredAt] as? Date else { return true }
        return link.deliveredAt.timeIntervalSince(deliveredAt) > deliveryTolerance
    }

    /// The earlier notification's record becomes this one's: its link, its time, and
    /// no read mark. Another Mac that did the same a moment before wins; its record
    /// is this notification's too.
    private func replace(_ serverRecord: CKRecord, with link: DeepLinkRecord, in database: CKDatabase) async throws -> CKRecord {
        Self.fill(serverRecord, with: link)
        let results = try await database.modifyRecords(saving: [serverRecord], deleting: [], savePolicy: .ifServerRecordUnchanged)
        do {
            return try results.saveResults[serverRecord.recordID]?.get() ?? serverRecord
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let newer = error.serverRecord else { throw error }
            return newer
        }
    }

    /// Tells the iPhone the item was read here: `readAt` on the link's record, which
    /// the iPhone subscribes to. Only the one field changes. Another Mac that saw
    /// the same notification may have rewritten the record meanwhile; then the
    /// server's copy is taken and the field set on that.
    func markRead(fingerprint: String, at date: Date = Date()) async {
        guard let database else { return }
        do {
            let record: CKRecord
            if let kept = savedRecords[fingerprint] {
                record = kept
            } else {
                record = try await database.record(for: CKRecord.ID(recordName: fingerprint))
            }
            try await save(record, readAt: date, in: database, retryingOnConflict: true)
            SafeDiagnosticLog.shared.record("sync: marked read")
        } catch {
            SafeDiagnosticLog.shared.record("sync: mark read failed: \(error.localizedDescription)")
        }
    }

    private func save(_ record: CKRecord, readAt date: Date, in database: CKDatabase, retryingOnConflict: Bool) async throws {
        record[DeepLinkRecordSchema.readAt] = date
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            if let saved = try results.saveResults[record.recordID]?.get() {
                savedRecords[record.recordID.recordName] = saved
            }
        } catch let error as CKError where error.code == .serverRecordChanged && retryingOnConflict {
            guard let serverRecord = error.serverRecord else { throw error }
            try await save(serverRecord, readAt: date, in: database, retryingOnConflict: false)
        }
    }

    /// How long opening waits for iCloud before it settles for the app.
    static let fetchDeadline: Duration = .seconds(4)
    /// How far apart a link's time and the item's may be, as the iPhone checks: a
    /// fingerprint is made of the text, so an earlier notification with the same
    /// words has a record of its own time.
    static let deliveryTolerance: TimeInterval = 15 * 60

    /// The link another Mac sent for a notification this one has no link for: one
    /// only the iPhone brought here, or one whose email or message this Mac's app
    /// hadn't fetched yet. An always-on Mac harvests what a laptop asleep or away
    /// never saw. Nil when there's none, it's another notification's with the same
    /// text, or iCloud doesn't answer in time.
    func fetchLink(fingerprint: String, deliveredNear date: Date) async -> DeepLinkRecord? {
        if !status.isAvailable {
            await refreshStatus()
        }
        guard status.isAvailable, let database else { return nil }
        let id = CKRecord.ID(recordName: fingerprint)
        let fetched = await ModelDeadline.value(within: Self.fetchDeadline) { () -> Result<DeepLinkRecord?, any Error> in
            do {
                return .success(Self.link(from: try await database.record(for: id), fingerprint: fingerprint))
            } catch {
                return .failure(error)
            }
        }
        switch fetched {
        case nil:
            SafeDiagnosticLog.shared.record("open: no answer from iCloud in time")
            return nil
        case .failure(let error as CKError) where error.code == .unknownItem:
            SafeDiagnosticLog.shared.record("open: no link from another Mac")
            return nil
        case .failure(let error):
            SafeDiagnosticLog.shared.record("open: link lookup failed: \(error.localizedDescription)")
            return nil
        case .success(let link):
            guard let link, Self.isSameDelivery(link, as: date) else {
                SafeDiagnosticLog.shared.record("open: another Mac's link is for another notification")
                return nil
            }
            SafeDiagnosticLog.shared.record("open: \(link.app) link from another Mac")
            return link
        }
    }

    static func isSameDelivery(_ link: DeepLinkRecord, as date: Date) -> Bool {
        abs(link.deliveredAt.timeIntervalSince(date)) <= deliveryTolerance
    }

    /// A record as another Mac (or this one) wrote it; nil when it lacks the URL or time.
    static func link(from record: CKRecord, fingerprint: String) -> DeepLinkRecord? {
        guard let urlString = record.encryptedValues[DeepLinkRecordSchema.url] as? String,
              let url = URL(string: urlString),
              let deliveredAt = record[DeepLinkRecordSchema.deliveredAt] as? Date else { return nil }
        return DeepLinkRecord(
            fingerprint: fingerprint,
            app: record[DeepLinkRecordSchema.app] as? String ?? "",
            url: url,
            opensExactContent: (record[DeepLinkRecordSchema.opensExactContent] as? Int ?? 0) != 0,
            deliveredAt: deliveredAt,
            expiresAt: record[DeepLinkRecordSchema.expiresAt] as? Date,
            readAt: record[DeepLinkRecordSchema.readAt] as? Date
        )
    }

    /// Deletes the records whose day is up. Run at launch and now and then.
    func deleteExpired(now: Date = Date()) async {
        let expired = expiryStore.expired(asOf: now)
        guard !expired.isEmpty, let database else { return }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: expired.map { CKRecord.ID(recordName: $0) })
            expiryStore.forget(recordNames: expired)
            for name in expired { savedRecords.removeValue(forKey: name) }
            SafeDiagnosticLog.shared.record("sync: deleted \(expired.count) expired links")
        } catch {
            SafeDiagnosticLog.shared.record("sync: delete failed: \(error.localizedDescription)")
        }
    }
}

/// The record names this Mac has written and when each expires, in UserDefaults:
/// fingerprints and dates, nothing about the notifications.
struct ExpiryStore {
    private static let key = "syncedRecordExpiries"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var entries: [String: Date] {
        get { (defaults.dictionary(forKey: Self.key) as? [String: Date]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    func remember(recordName: String, expiresAt: Date) {
        var entries = entries
        entries[recordName] = expiresAt
        self.entries = entries
    }

    func expired(asOf now: Date) -> [String] {
        entries.filter { $0.value <= now }.map(\.key)
    }

    func forget(recordNames: [String]) {
        var entries = entries
        for name in recordNames { entries.removeValue(forKey: name) }
        self.entries = entries
    }
}
