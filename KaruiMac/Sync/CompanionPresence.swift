import CloudKit
import Foundation
import KaruiLinkKit

/// Tells the iPhone this Mac is here: one `Companion` record, written at launch and
/// refreshed every hour while the app runs. The iPhone skips waiting for a link
/// when no Mac has been seen for a day, and shows the Mac in its settings.
actor CompanionPresence {
    static let interval: Duration = .seconds(60 * 60)
    private static let identifierKey = "companionID"

    private let database: CKDatabase?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        defaults: UserDefaults = .standard
    ) {
        database = container?.privateCloudDatabase
        self.defaults = defaults
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                await announce()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func announce() async {
        guard let database else { return }
        let record = CKRecord(
            recordType: CompanionRecordSchema.recordType,
            recordID: CKRecord.ID(recordName: identifier)
        )
        record[CompanionRecordSchema.name] = Host.current().localizedName ?? "Mac"
        record[CompanionRecordSchema.appVersion] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        record[CompanionRecordSchema.lastSeenAt] = Date()
        record[CompanionRecordSchema.apps] = KnownApp.allCases.map(\.rawValue)
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            SafeDiagnosticLog.shared.record("presence: announced")
        } catch {
            SafeDiagnosticLog.shared.record("presence: announce failed: \(error.localizedDescription)")
        }
    }

    /// Stable across launches, so the iPhone sees one Mac, not one per launch.
    private var identifier: String { Self.identifier(defaults: defaults) }

    static func identifier(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: identifierKey) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: identifierKey)
        return created
    }
}
