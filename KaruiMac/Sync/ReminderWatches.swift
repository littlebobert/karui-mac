import CloudKit
import Foundation
import KaruiLinkKit

/// The iPhone's open deadline reminders about Messages and Spark notifications, and
/// what the person has sent in each one's conversation since. A reply found here goes
/// back on the reminder's record, encrypted; the iPhone decides whether it finishes
/// the task and clears the reminder. The iPhone has the switch: with it off, there
/// are no records to watch.
actor ReminderWatches {
    /// How often iCloud is asked for the reminders: they change a few times a day.
    static let fetchInterval: TimeInterval = 5 * 60

    private let database: CKDatabase?
    private let findReply: @Sendable (ReminderWatchRecord) -> SentReply?
    private var records: [CKRecord] = []
    private var fetchedAt: Date?
    private var lastSummary = ""

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        findReply: @escaping @Sendable (ReminderWatchRecord) -> SentReply? = ReminderWatches.findReply
    ) {
        database = container?.privateCloudDatabase
        self.findReply = findReply
    }

    /// Messages by the notification's text; Spark by its subject, the notification's subtitle.
    static let findReply: @Sendable (ReminderWatchRecord) -> SentReply? = { watch in
        switch KnownApp(rawValue: watch.app) {
        case .messages: (try? ChatDatabase.standard.reply(toText: watch.body, near: watch.deliveredAt)) ?? nil
        case .spark: SparkHarvester().reply(toSubject: watch.subtitle ?? "", near: watch.deliveredAt)
        default: nil
        }
    }

    /// Looks for a reply to each reminder, fetching the reminders again when it's
    /// been a while, and saves any newer than the one on its record.
    func check(now: Date = Date()) async {
        guard let database else { return }
        if fetchedAt.map({ now.timeIntervalSince($0) >= Self.fetchInterval }) ?? true {
            await fetch(from: database, now: now)
        }
        var changed: [CKRecord] = []
        for record in records {
            guard let watch = Self.watch(from: record), watch.expiresAt > now,
                  let reply = Self.newReply(findReply(watch), over: watch) else { continue }
            record[ReminderWatchRecordSchema.repliedAt] = reply.sentAt as NSDate
            record.encryptedValues[ReminderWatchRecordSchema.replyText] = reply.text
            changed.append(record)
        }
        guard !changed.isEmpty else { return }
        do {
            let (saved, _) = try await database.modifyRecords(saving: changed, deleting: [], savePolicy: .changedKeys)
            SafeDiagnosticLog.shared.record("reminders: found \(changed.count) repl\(changed.count == 1 ? "y" : "ies") to send")
            for case (let id, .success(let record)) in saved {
                if let index = records.firstIndex(where: { $0.recordID == id }) { records[index] = record }
            }
        } catch {
            SafeDiagnosticLog.shared.record("reminders: saving replies failed: \(error.localizedDescription)")
        }
    }

    /// A reply worth sending: one found, newer than the one already sent.
    static func newReply(_ reply: SentReply?, over watch: ReminderWatchRecord) -> SentReply? {
        guard let reply else { return nil }
        if let sent = watch.repliedAt, reply.sentAt.timeIntervalSince(sent) < 1 { return nil }
        return reply
    }

    private func fetch(from database: CKDatabase, now: Date) async {
        let query = CKQuery(
            recordType: ReminderWatchRecordSchema.recordType,
            predicate: NSPredicate(format: "%K > %@", ReminderWatchRecordSchema.expiresAt, now as NSDate)
        )
        do {
            var (matches, cursor) = try await database.records(matching: query, resultsLimit: 200)
            var found = matches.compactMap { try? $0.1.get() }
            while let current = cursor {
                (matches, cursor) = try await database.records(continuingMatchFrom: current, resultsLimit: 200)
                found += matches.compactMap { try? $0.1.get() }
            }
            records = found
            fetchedAt = now
            let summary = "reminders: watching \(found.count) for replies"
            if summary != lastSummary {
                lastSummary = summary
                SafeDiagnosticLog.shared.record(summary)
            }
        } catch {
            // Before the record type is deployed, or offline: tried again next time.
            fetchedAt = now
            SafeDiagnosticLog.shared.record("reminders: fetch failed: \(error.localizedDescription)")
        }
    }

    static func watch(from record: CKRecord) -> ReminderWatchRecord? {
        guard let id = ReminderWatchRecord.reminderID(recordName: record.recordID.recordName),
              let app = record[ReminderWatchRecordSchema.app] as? String,
              let deliveredAt = record[ReminderWatchRecordSchema.deliveredAt] as? Date,
              let expiresAt = record[ReminderWatchRecordSchema.expiresAt] as? Date else { return nil }
        return ReminderWatchRecord(
            reminderID: id,
            app: app,
            deliveredAt: deliveredAt,
            expiresAt: expiresAt,
            title: record.encryptedValues[ReminderWatchRecordSchema.title] as? String ?? "",
            subtitle: record.encryptedValues[ReminderWatchRecordSchema.subtitle] as? String,
            body: record.encryptedValues[ReminderWatchRecordSchema.body] as? String ?? "",
            repliedAt: record[ReminderWatchRecordSchema.repliedAt] as? Date,
            replyText: record.encryptedValues[ReminderWatchRecordSchema.replyText] as? String
        )
    }
}
