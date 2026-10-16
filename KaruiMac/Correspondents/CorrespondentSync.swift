import CloudKit
import Foundation
import KaruiLinkKit

/// Sends the iPhone the hashes of everyone this Mac knows the person has written
/// to, once a day, as this Mac's `Correspondents` record. The iPhone treats a
/// notification from one of them the way it treats a saved contact.
actor CorrespondentSync {
    static let interval: Duration = .seconds(24 * 60 * 60)

    private let sources: [any CorrespondentSource]
    private let database: CKDatabase?
    private let recordName: String
    private var task: Task<Void, Never>?

    init(
        sources: [any CorrespondentSource],
        companionIdentifier: String,
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil
    ) {
        self.sources = sources
        database = container?.privateCloudDatabase
        recordName = companionIdentifier + "-correspondents"
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                await send()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func send() async {
        var hashes = Set<String>()
        for source in sources {
            do {
                for handle in try source.handles() {
                    if let hash = CorrespondentHash.make(handle) { hashes.insert(hash) }
                }
            } catch {
                SafeDiagnosticLog.shared.record("correspondents: \(type(of: source)) failed: \(error)")
            }
        }
        // Sorting on this Mac uses them as the iPhone does.
        KnownCorrespondentHashes.shared.replace(with: hashes)
        guard let database else { return }
        // Sorted so the record only changes when the people do.
        let list = Array(hashes).sorted().prefix(CorrespondentRecordSchema.maximumHashes)
        let record = CKRecord(
            recordType: CorrespondentRecordSchema.recordType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        record[CorrespondentRecordSchema.hashes] = Array(list)
        record[CorrespondentRecordSchema.count] = list.count
        record[CorrespondentRecordSchema.updatedAt] = Date()
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            SafeDiagnosticLog.shared.record("correspondents: sent \(list.count) hashes")
        } catch {
            SafeDiagnosticLog.shared.record("correspondents: send failed: \(error.localizedDescription)")
        }
    }
}
