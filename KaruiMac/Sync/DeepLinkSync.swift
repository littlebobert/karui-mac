import CloudKit
import Foundation
import KaruiLinkKit

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

    func send(_ link: DeepLinkRecord) async {
        if !status.isAvailable {
            await refreshStatus()
        }
        guard status.isAvailable, let database else {
            SafeDiagnosticLog.shared.record("sync: skipped, iCloud \(status)")
            return
        }
        let record = CKRecord(
            recordType: DeepLinkRecordSchema.recordType,
            recordID: CKRecord.ID(recordName: link.fingerprint)
        )
        record[DeepLinkRecordSchema.fingerprint] = link.fingerprint
        record[DeepLinkRecordSchema.app] = link.app
        record.encryptedValues[DeepLinkRecordSchema.url] = link.url.absoluteString
        record[DeepLinkRecordSchema.opensExactContent] = link.opensExactContent ? 1 : 0
        record[DeepLinkRecordSchema.deliveredAt] = link.deliveredAt
        record[DeepLinkRecordSchema.expiresAt] = link.expiresAt
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            expiryStore.remember(recordName: link.fingerprint, expiresAt: link.expiresAt)
            SafeDiagnosticLog.shared.record("sync: sent \(link.app) link")
        } catch {
            SafeDiagnosticLog.shared.record("sync: send failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the records whose day is up. Run at launch and now and then.
    func deleteExpired(now: Date = Date()) async {
        let expired = expiryStore.expired(asOf: now)
        guard !expired.isEmpty, let database else { return }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: expired.map { CKRecord.ID(recordName: $0) })
            expiryStore.forget(recordNames: expired)
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
