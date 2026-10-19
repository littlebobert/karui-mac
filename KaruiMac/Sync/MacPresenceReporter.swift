import AppKit
import CloudKit
import CoreGraphics
import Foundation
import KaruiLinkKit

/// Tells the iPhone whether the person is using this Mac (`MacPresenceRecordSchema`),
/// so Karui there alerts quietly while the Mac has the notification in front of
/// them. In use means a key or the pointer moved within the last minute, with the
/// screen unlocked and awake. Written every half minute while in use, and at once
/// when that ends; a Mac that stops writing goes stale on the iPhone by itself.
@MainActor
final class MacPresenceReporter {
    /// No input for this long counts as away.
    static let idleThreshold: TimeInterval = 60
    private let database: CKDatabase?
    private let recordName: String
    private var timer: Timer?
    private var isLocked = false
    private var isAsleep = false
    /// What was last written, so an unchanged "away" isn't written again.
    private var lastWritten: Bool?
    private var observers: [NSObjectProtocol] = []
    var isEnabled: () -> Bool = { true }

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        recordName: String = CompanionPresence.identifier()
    ) {
        database = container?.privateCloudDatabase
        self.recordName = recordName
    }

    func start() {
        guard timer == nil, database != nil else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = true; self?.report() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = false; self?.report() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = true; self?.report() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = false; self?.report() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: MacPresenceRecordSchema.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    /// Whether the person is using the Mac now.
    var isInUse: Bool {
        guard isEnabled(), !isLocked, !isAsleep else { return false }
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < Self.idleThreshold
    }

    /// In use: written each time, so the iPhone sees a fresh time. Away: written once.
    private func report() {
        let inUse = isInUse
        guard inUse || lastWritten != false, let database else { return }
        lastWritten = inUse
        let record = CKRecord(recordType: MacPresenceRecordSchema.recordType, recordID: CKRecord.ID(recordName: recordName))
        record[MacPresenceRecordSchema.isAtMac] = inUse ? 1 : 0
        record[MacPresenceRecordSchema.lastActiveAt] = inUse ? Date() : nil
        record[MacPresenceRecordSchema.name] = Host.current().localizedName ?? "Mac"
        Task {
            do {
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            } catch {
                SafeDiagnosticLog.shared.record("presence: status failed: \(error.localizedDescription)")
                await MainActor.run { self.lastWritten = nil }
            }
        }
    }
}
