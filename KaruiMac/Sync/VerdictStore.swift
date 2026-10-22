import CloudKit
import Foundation
import KaruiLinkKit

/// Karui's verdicts, from the iPhone's `Verdict` records: the day's, fetched every
/// so often. Those named by a fingerprint the inbox knows go with that
/// notification; those carrying text are notifications only the iPhone got, which
/// the inbox shows on their own.
actor VerdictStore {
    /// A fallback now that pushes bring each change (`MacSubscriptions`).
    static let pollInterval: Duration = .seconds(60)
    /// The full day is re-read this often, for categories and read marks that changed.
    static let fullPassInterval: Duration = .seconds(5 * 60)
    static let window: TimeInterval = VerdictRecord.lifetime
    /// The first full pass reaches back as far as the inbox is kept.
    static let firstPassWindow: TimeInterval = InboxStore.retention
    private var hasCompletedFullPass = false

    private let database: CKDatabase?
    private var task: Task<Void, Never>?
    private var lastSummary = ""
    private let found: @Sendable ([VerdictRecord]) -> Void
    private let awaiting: @Sendable () async -> [String]

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        awaiting: @escaping @Sendable () async -> [String],
        found: @escaping @Sendable ([VerdictRecord]) -> Void
    ) {
        database = container?.privateCloudDatabase
        self.awaiting = awaiting
        self.found = found
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            var lastFullPass = ContinuousClock.now - Self.fullPassInterval
            while !Task.isCancelled {
                if ContinuousClock.now - lastFullPass >= Self.fullPassInterval {
                    await fetch()
                    lastFullPass = ContinuousClock.now
                } else {
                    await fetchAwaiting()
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Only the verdicts the inbox is still waiting for, by name: cheap, and
    /// enough between full passes.
    func fetchAwaiting() async {
        guard let database else { return }
        let fingerprints = await awaiting()
        guard !fingerprints.isEmpty else { return }
        let ids = fingerprints.map { CKRecord.ID(recordName: VerdictRecordSchema.recordName(fingerprint: $0)) }
        do {
            let results = try await database.records(for: ids)
            let verdicts = results.values.compactMap { try? Self.verdict(from: $0.get()) }
            if !verdicts.isEmpty { found(verdicts) }
        } catch {
            SafeDiagnosticLog.shared.record("verdicts: fetch failed: \(error.localizedDescription)")
        }
    }

    func fetch(now: Date = Date()) async {
        guard let database else { return }
        let reach = hasCompletedFullPass ? Self.window : Self.firstPassWindow
        let query = CKQuery(
            recordType: VerdictRecordSchema.recordType,
            predicate: NSPredicate(format: "%K > %@", VerdictRecordSchema.triagedAt, now.addingTimeInterval(-reach) as NSDate)
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
        hasCompletedFullPass = true
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

    /// One verdict, named by a push.
    func fetch(recordID: CKRecord.ID) async {
        guard let database else { return }
        do {
            let record = try await database.record(for: recordID)
            if let verdict = Self.verdict(from: record) { found([verdict]) }
        } catch let error as CKError where error.code == .unknownItem {
            // Deleted on the iPhone: the next full pass drops it.
        } catch {
            SafeDiagnosticLog.shared.record("verdicts: fetch by push failed: \(error.localizedDescription)")
        }
    }

    /// What the person did here, onto the verdict record, for the iPhone to apply.
    enum Action {
        case read
        case category(String)
        case delete
        /// A deletion taken back before the iPhone acted on it, or restored after.
        case undelete
    }

    func apply(_ action: Action, to fingerprints: [String]) async {
        guard let database, !fingerprints.isEmpty else { return }
        let ids = fingerprints.map { CKRecord.ID(recordName: VerdictRecordSchema.recordName(fingerprint: $0)) }
        do {
            let fetched = try await database.records(for: ids)
            let now = Date()
            let records = fetched.values.compactMap { try? $0.get() }
            for record in records {
                switch action {
                case .read: record[VerdictRecordSchema.readAt] = now
                case .category(let category): record[VerdictRecordSchema.requestedCategory] = category
                case .delete: record[VerdictRecordSchema.deletedAt] = now
                case .undelete: record[VerdictRecordSchema.deletedAt] = nil
                }
                record[VerdictRecordSchema.actionAt] = now
            }
            guard !records.isEmpty else { return }
            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
            SafeDiagnosticLog.shared.record("verdicts: \(action) sent for \(records.count) of \(fingerprints.count)")
        } catch {
            SafeDiagnosticLog.shared.record("verdicts: action failed: \(error.localizedDescription)")
        }
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
            body: record.encryptedValues[VerdictRecordSchema.body] as? String,
            readAt: record[VerdictRecordSchema.readAt] as? Date,
            requestedCategory: record[VerdictRecordSchema.requestedCategory] as? String,
            deletedAt: record[VerdictRecordSchema.deletedAt] as? Date,
            subtitle: record.encryptedValues[VerdictRecordSchema.subtitle] as? String,
            sender: record.encryptedValues[VerdictRecordSchema.sender] as? String,
            recipients: record.encryptedValues[VerdictRecordSchema.recipients] as? String,
            engine: record[VerdictRecordSchema.engine] as? String
        )
    }
}
