import CloudKit
import Foundation
import KaruiLinkKit

/// Notifications only this Mac received, sent to the iPhone to sort: an app can hold a
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
        var readAt: Date?
        /// Sorted here with the model, not by the rules standing in for it.
        let macVerdict: MacVerdict?

        init(_ item: Inbox.Item) {
            fingerprint = item.fingerprint
            app = item.app
            title = item.title
            subtitle = item.subtitle
            body = item.body
            deliveredAt = item.deliveredAt
            readAt = item.readAt
            macVerdict = item.macVerdict.flatMap { $0.isModelFallback ? nil : $0 }
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
    /// sorted it after all, or another Mac asked first. One that exists for an earlier
    /// notification with the same text is neither, and the request goes again under a
    /// name of its own (`repeatRecordName`). Returns how many went.
    @discardableResult
    func send(_ requests: [Request], now: Date = Date()) async -> Int {
        guard let database, !requests.isEmpty else { return 0 }
        await deleteSpentRepeats(in: database, now: now)
        var settled = Set<String>()
        var sent = 0
        var existing = 0
        var failures: [String] = []
        // A new record with no change tag: the save fails for one that exists, and the
        // failure carries the record iCloud has.
        let first = await save(
            Self.unique(requests).map { ($0, VerdictRecordSchema.recordName(fingerprint: $0.fingerprint)) },
            in: database, now: now
        )
        failures += first.failures
        sent += first.created.count
        settled.formUnion(first.created.map(\.fingerprint))
        var repeats: [Request] = []
        for (request, server) in first.taken {
            guard let server, Self.isOfEarlierNotification(server, than: request.deliveredAt) else {
                existing += 1
                settled.insert(request.fingerprint)
                continue
            }
            var again = request
            // Read on another Mac since it arrived, the mark on the earlier one's
            // record and not here yet: the iPhone files it read all the same.
            if again.readAt == nil, let mark = server[VerdictRecordSchema.readAt] as? Date, mark >= request.deliveredAt {
                again.readAt = mark
            }
            repeats.append(again)
        }
        if !repeats.isEmpty {
            let second = await save(repeats.map { ($0, Self.repeatRecordName(for: $0)) }, in: database, now: now)
            failures += second.failures
            sent += second.created.count
            // Taken: another Mac got it at the same moment and asked first.
            existing += second.taken.count
            settled.formUnion(second.created.map(\.fingerprint))
            settled.formUnion(second.taken.map(\.0.fingerprint))
            var names = repeatNames()
            for request in second.created { names[Self.repeatRecordName(for: request)] = now.timeIntervalSince1970 }
            defaults.set(names, forKey: Self.repeatNamesKey)
        }
        var dates = requestedDates(now: now)
        for fingerprint in settled { dates[fingerprint] = now.timeIntervalSince1970 }
        defaults.set(dates, forKey: Self.requestedKey)
        SafeDiagnosticLog.shared.record(
            "sort requests: \(sent) sent, \(existing) already on iCloud"
                + (repeats.isEmpty ? "" : ", \(repeats.count) a repeat of an earlier one")
                + (failures.isEmpty ? "" : ", failed: \(failures.prefix(2).joined(separator: " / "))")
        )
        return sent
    }

    /// The record iCloud has under a fingerprint is of an earlier notification when it
    /// was sorted, or asked about, more than the verdict's reach before this one
    /// arrived. The fingerprint is the app and the text, so a calendar alert copied to
    /// several days, or "sent a photo." from one person, is one record for all of
    /// them. Taken for this notification's, as it was, the iPhone was never asked
    /// about a repeat it didn't get itself, which then had no verdict on any Mac, and
    /// read on one Mac stayed unread on the others.
    static func isOfEarlierNotification(_ record: CKRecord, than deliveredAt: Date) -> Bool {
        let times = [VerdictRecordSchema.triagedAt, VerdictRecordSchema.deliveredAt].compactMap { record[$0] as? Date }
        guard let latest = times.max() else { return false }
        return latest < deliveredAt.addingTimeInterval(-Inbox.verdictMatchWindow)
    }

    /// A repeat's request has a record of its own, named by the fingerprint and when
    /// the notification arrived: the iPhone is woken only by a request that's a new
    /// record, and the one the fingerprint names is taken. The iPhone files the
    /// notification under the fingerprint its text makes, so its verdict goes onto
    /// that record like any other, in place of the earlier one's; this one is only
    /// the asking, and goes after a day (`deleteSpentRepeats`).
    static func repeatRecordName(for request: Request) -> String {
        VerdictRecordSchema.recordName(fingerprint: request.fingerprint) + "@\(Int(request.deliveredAt.timeIntervalSince1970))"
    }

    static func record(for request: Request, named name: String, now: Date) -> CKRecord {
        let record = CKRecord(recordType: VerdictRecordSchema.recordType, recordID: CKRecord.ID(recordName: name))
        record[VerdictRecordSchema.app] = request.app
        record.encryptedValues[VerdictRecordSchema.title] = request.title
        record.encryptedValues[VerdictRecordSchema.subtitle] = request.subtitle
        record.encryptedValues[VerdictRecordSchema.body] = request.body
        record[VerdictRecordSchema.deliveredAt] = request.deliveredAt
        // Read here already: the iPhone files it without alerting.
        record[VerdictRecordSchema.readAt] = request.readAt
        record[VerdictRecordSchema.sortRequestedAt] = now
        if let verdict = request.macVerdict {
            record[VerdictRecordSchema.macCategory] = verdict.category
            record[VerdictRecordSchema.macEngine] = verdict.engine
            record[VerdictRecordSchema.macConfidence] = verdict.confidence
            record[VerdictRecordSchema.macInterest] = verdict.interest
            record.encryptedValues[VerdictRecordSchema.macReason] = verdict.reason
        }
        return record
    }

    /// What became of requests saved as new records: created, or refused because the
    /// name is taken, with the record that has it when iCloud sent it along.
    private struct Saved {
        var created: [Request] = []
        var taken: [(Request, CKRecord?)] = []
        var failures: [String] = []
    }

    private func save(_ named: [(request: Request, name: String)], in database: CKDatabase, now: Date) async -> Saved {
        var saved = Saved()
        let requests = Dictionary(named.map { ($0.name, $0.request) }, uniquingKeysWith: { first, _ in first })
        do {
            let results = try await database.modifyRecords(
                saving: requests.map { Self.record(for: $0.value, named: $0.key, now: now) },
                deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
            )
            for (id, result) in results.saveResults {
                guard let request = requests[id.recordName] else { continue }
                switch result {
                case .success:
                    saved.created.append(request)
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    saved.taken.append((request, error.serverRecord))
                case .failure(let error):
                    // Tried again on the next pass.
                    saved.failures.append(error.localizedDescription)
                }
            }
        } catch {
            saved.failures.append(error.localizedDescription)
        }
        return saved
    }

    /// The records made for repeats, by name, with when. Nothing is written onto
    /// them, and the iPhone leaves a request alone after a day, so they go then.
    private static let repeatNamesKey = "sortRequests.repeatRecords"

    private func repeatNames() -> [String: TimeInterval] {
        defaults.dictionary(forKey: Self.repeatNamesKey) as? [String: TimeInterval] ?? [:]
    }

    private func deleteSpentRepeats(in database: CKDatabase, now: Date) async {
        var names = repeatNames()
        let cutoff = now.addingTimeInterval(-VerdictRecord.lifetime).timeIntervalSince1970
        let spent = names.filter { $0.value < cutoff }.map(\.key)
        guard !spent.isEmpty,
              let results = try? await database.modifyRecords(saving: [], deleting: spent.map { CKRecord.ID(recordName: $0) })
        else { return }
        for (id, result) in results.deleteResults {
            switch result {
            case .success:
                names.removeValue(forKey: id.recordName)
            case .failure(let error as CKError) where error.code == .unknownItem:
                // Gone already: what was wanted.
                names.removeValue(forKey: id.recordName)
            case .failure:
                // Tried again with the next requests.
                break
            }
        }
        defaults.set(names, forKey: Self.repeatNamesKey)
    }

    /// One request per fingerprint, the first kept. Two inbox rows can share one (the
    /// same notification harvested twice), and CloudKit refuses a whole batch that
    /// saves a record twice ("You can't save the same record twice"), so every pass
    /// failed until the pair aged out of the reach.
    static func unique(_ requests: [Request]) -> [Request] {
        var seen = Set<String>()
        return requests.filter { seen.insert($0.fingerprint).inserted }
    }

    private func requestedDates(now: Date) -> [String: TimeInterval] {
        let all = defaults.dictionary(forKey: Self.requestedKey) as? [String: TimeInterval] ?? [:]
        let cutoff = now.addingTimeInterval(-Self.reach * 2).timeIntervalSince1970
        return all.filter { $0.value >= cutoff }
    }
}
