import CloudKit
import Foundation
import KaruiLinkKit

/// Karui's verdicts, from the iPhone's `Verdict` records: the day's, fetched every
/// so often. Those named by a fingerprint the inbox knows go with that
/// notification; those carrying text are notifications only the iPhone got, which
/// the inbox shows on their own.
actor VerdictStore {
    static let pollInterval: Duration = .seconds(20)
    static let window: TimeInterval = VerdictRecord.lifetime

    private let database: CKDatabase?
    private var task: Task<Void, Never>?
    private var lastSummary = ""
    private let found: @Sendable ([VerdictRecord]) -> Void

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        found: @escaping @Sendable ([VerdictRecord]) -> Void
    ) {
        database = container?.privateCloudDatabase
        self.found = found
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                await fetch()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func fetch(now: Date = Date()) async {
        guard let database else { return }
        let query = CKQuery(
            recordType: VerdictRecordSchema.recordType,
            predicate: NSPredicate(format: "%K > %@", VerdictRecordSchema.triagedAt, now.addingTimeInterval(-Self.window) as NSDate)
        )
        var verdicts: [VerdictRecord] = []
        var cursor: CKQueryOperation.Cursor?
        do {
            var (matches, next) = try await database.records(matching: query, resultsLimit: 200)
            cursor = next
            verdicts += matches.compactMap { try? Self.verdict(from: $0.1.get()) }
            while let current = cursor {
                (matches, next) = try await database.records(continuingMatchFrom: current, resultsLimit: 200)
                cursor = next
                verdicts += matches.compactMap { try? Self.verdict(from: $0.1.get()) }
            }
        } catch {
            SafeDiagnosticLog.shared.record("verdicts: fetch failed: \(error.localizedDescription)")
            return
        }
        // Counts only, when they change: which apps the iPhone sent, and how many carry text.
        let withText = verdicts.filter { $0.title != nil || $0.body != nil }.count
        let apps = Dictionary(grouping: verdicts, by: \.app).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        let summary = "verdicts: \(verdicts.count) in the last day (\(withText) with text): \(apps)"
        if summary != lastSummary {
            lastSummary = summary
            SafeDiagnosticLog.shared.record(summary)
        }
        found(verdicts)
    }

    static func verdict(from record: CKRecord) -> VerdictRecord? {
        guard let fingerprint = VerdictRecordSchema.fingerprint(recordName: record.recordID.recordName),
              let app = record[VerdictRecordSchema.app] as? String,
              let category = record[VerdictRecordSchema.category] as? String,
              let triagedAt = record[VerdictRecordSchema.triagedAt] as? Date else {
            return nil
        }
        return VerdictRecord(
            fingerprint: fingerprint,
            app: app,
            category: category,
            interest: record[VerdictRecordSchema.interest] as? Int,
            reason: record.encryptedValues[VerdictRecordSchema.reason] as? String ?? "",
            triagedAt: triagedAt,
            isUnread: (record[VerdictRecordSchema.isUnread] as? Int ?? 0) != 0,
            title: record.encryptedValues[VerdictRecordSchema.title] as? String,
            body: record.encryptedValues[VerdictRecordSchema.body] as? String
        )
    }
}
