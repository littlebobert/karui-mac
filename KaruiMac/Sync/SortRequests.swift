import CloudKit
import Foundation
import KaruiLinkKit

/// Notifications only this Mac got, sent to the iPhone to sort: an app can hold a
/// push back from the phone while the person is at the Mac, or the phone can be
/// off. Each goes as a `Verdict` record named by its fingerprint, with the text
/// (end-to-end encrypted), when it arrived, and no category; the iPhone sorts it,
/// files it in History, and writes its verdict onto the same record, which the
/// verdict fetch here then picks up like any other.
actor SortRequests {
    /// Asked about only this long after arriving: a Mac starting up shouldn't send
    /// the whole day, and the iPhone files each one at the time it arrived.
    static let reach: TimeInterval = 6 * 60 * 60
    /// At most this many at once; the rest go on the next pass.
    static let batchLimit = 50
    private static let requestedKey = "sortRequests.requested"

    struct Request: Sendable {
        let fingerprint: String
        let app: String
        let title: String?
        let subtitle: String?
        let body: String?
        let deliveredAt: Date
        let readAt: Date?

        init(_ item: Inbox.Item) {
            fingerprint = item.fingerprint
            app = item.app
            title = item.title
            subtitle = item.subtitle
            body = item.body
            deliveredAt = item.deliveredAt
            readAt = item.readAt
        }
    }

    private let database: CKDatabase?
    private let defaults: UserDefaults

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        defaults: UserDefaults = .standard
    ) {
        database = container?.privateCloudDatabase
        self.defaults = defaults
    }

    /// Fingerprints already asked about, or found already sorted, within the reach.
    func requested(now: Date = Date()) -> Set<String> {
        Set(requestedDates(now: now).keys)
    }

    /// Creates each request, unless its record already exists: then the iPhone has
    /// sorted it after all, or another Mac asked first. Returns how many went.
    @discardableResult
    func send(_ requests: [Request], now: Date = Date()) async -> Int {
        guard let database, !requests.isEmpty else { return 0 }
        let records = requests.map { request -> CKRecord in
            let record = CKRecord(
                recordType: VerdictRecordSchema.recordType,
                recordID: CKRecord.ID(recordName: VerdictRecordSchema.recordName(fingerprint: request.fingerprint))
            )
            record[VerdictRecordSchema.app] = request.app
            record.encryptedValues[VerdictRecordSchema.title] = request.title
            record.encryptedValues[VerdictRecordSchema.subtitle] = request.subtitle
            record.encryptedValues[VerdictRecordSchema.body] = request.body
            record[VerdictRecordSchema.deliveredAt] = request.deliveredAt
            // Read here already: the iPhone files it without alerting.
            record[VerdictRecordSchema.readAt] = request.readAt
            record[VerdictRecordSchema.sortRequestedAt] = now
            return record
        }
        var settled = Set<String>()
        var sent = 0
        var existing = 0
        var failures: [String] = []
        do {
            // A new record with no change tag: the save fails for one that exists.
            let results = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
            )
            for (id, result) in results.saveResults {
                guard let fingerprint = VerdictRecordSchema.fingerprint(recordName: id.recordName) else { continue }
                switch result {
                case .success:
                    sent += 1
                    settled.insert(fingerprint)
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    existing += 1
                    settled.insert(fingerprint)
                case .failure(let error):
                    // Tried again on the next pass.
                    failures.append(error.localizedDescription)
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        var dates = requestedDates(now: now)
        for fingerprint in settled { dates[fingerprint] = now.timeIntervalSince1970 }
        defaults.set(dates, forKey: Self.requestedKey)
        SafeDiagnosticLog.shared.record(
            "sort requests: \(sent) sent, \(existing) already on iCloud"
                + (failures.isEmpty ? "" : ", failed: \(failures.prefix(2).joined(separator: " / "))")
        )
        return sent
    }

    private func requestedDates(now: Date) -> [String: TimeInterval] {
        let all = defaults.dictionary(forKey: Self.requestedKey) as? [String: TimeInterval] ?? [:]
        let cutoff = now.addingTimeInterval(-Self.reach * 2).timeIntervalSince1970
        return all.filter { $0.value >= cutoff }
    }
}
