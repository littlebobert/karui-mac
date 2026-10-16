import CloudKit
import Foundation
import KaruiLinkKit
import KaruiSorting
import Observation

/// The iPhone's sorting settings and what it learned from fixes, so this Mac sorts a
/// notification exactly as the iPhone would (`SortingSettingsRecordSchema`). The
/// iPhone writes them while Show History on your Mac is on; they're fetched every so
/// often and kept in Application Support, so sorting works offline too. When the
/// iPhone deletes the record, they go from here too.
@MainActor
@Observable
final class SortingSettingsStore {
    static let refreshInterval: Duration = .seconds(10 * 60)
    private(set) var policy: TriagePolicy?
    /// When the iPhone last changed them.
    private(set) var updatedAt: Date?
    /// iCloud has answered at least once, so a missing policy means the iPhone sent none.
    private(set) var hasChecked = false
    @ObservationIgnored private let database: CKDatabase?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil
    ) {
        database = container?.privateCloudDatabase
        if let data = try? Data(contentsOf: MacSortingFiles.policy) {
            policy = try? JSONDecoder().decode(TriagePolicy.self, from: data)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func refresh() async {
        guard let database else { return }
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: SortingSettingsRecordSchema.recordName))
            apply(record)
            hasChecked = true
        } catch let error as CKError where error.code == .unknownItem {
            // Never sent, or Show History on your Mac was turned off on the iPhone.
            if policy != nil { SafeDiagnosticLog.shared.record("sorting settings: gone from iCloud, cleared") }
            clear()
            hasChecked = true
        } catch {
            SafeDiagnosticLog.shared.record("sorting settings: fetch failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ record: CKRecord) {
        guard let json = record.encryptedValues[SortingSettingsRecordSchema.policy] as? String,
              let policy = try? JSONDecoder().decode(TriagePolicy.self, from: Data(json.utf8)) else {
            SafeDiagnosticLog.shared.record("sorting settings: unreadable")
            return
        }
        let updatedAt = record[SortingSettingsRecordSchema.updatedAt] as? Date
        guard updatedAt != self.updatedAt || self.policy == nil else { return }
        self.policy = policy
        self.updatedAt = updatedAt
        try? FileManager.default.createDirectory(at: MacSortingFiles.folder, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: MacSortingFiles.policy, options: .atomic)
        let corrections = (record.encryptedValues[SortingSettingsRecordSchema.corrections] as? String)
            .flatMap { try? JSONDecoder().decode([CorrectionExample].self, from: Data($0.utf8)) } ?? []
        CorrectionMemory.update(MacSortingFiles.corrections) { $0 = corrections }
        if let threshold = record[SortingSettingsRecordSchema.correctionThreshold] as? Double {
            UserDefaults.standard.set(threshold, forKey: CorrectionMemory.thresholdKey)
        }
        SafeDiagnosticLog.shared.record("sorting settings: updated, \(corrections.count) corrections")
    }

    private func clear() {
        policy = nil
        updatedAt = nil
        try? FileManager.default.removeItem(at: MacSortingFiles.policy)
        try? FileManager.default.removeItem(at: MacSortingFiles.corrections)
    }
}
