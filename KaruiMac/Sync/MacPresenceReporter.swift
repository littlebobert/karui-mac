import AppKit
import CloudKit
import CoreGraphics
import Foundation
import KaruiLinkKit

/// Tells the iPhone whether the person is using this Mac (`MacPresenceRecordSchema`),
/// so Karui there alerts quietly while the Mac has the notification in front of
/// them. In use means a key or the pointer moved within the last few minutes, with
/// the screen unlocked and awake. Written every half minute while in use, and at
/// once when that ends; a Mac that stops writing goes stale on the iPhone by itself.
///
/// The writes keep App Nap off while the screen is unlocked and awake: napping, the
/// app's timers slip by minutes once its window is covered, the record goes stale,
/// and the iPhone alerts though the person is right here.
@MainActor
final class MacPresenceReporter {
    /// No input for this long counts as away. Long enough to read a message without
    /// touching anything; walking away usually locks the screen or puts it to sleep.
    static let idleThreshold: TimeInterval = 3 * 60
    private let database: CKDatabase?
    private let recordName: String
    private var timer: Timer?
    private var isLocked = false
    private var isAsleep = false
    /// What was last written, so an unchanged "away" isn't written again.
    private var lastWritten: Bool?
    private var lastTick: Date?
    /// Logged once a launch, so the log shows the record reaches iCloud at all.
    private var hasSaved = false
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    var isEnabled: () -> Bool = { true }

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        // Its own name: record names are unique in a zone whatever the type, and
        // the Companion record already has this Mac's identifier.
        recordName: String = "presence-" + CompanionPresence.identifier()
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
            MainActor.assumeIsolated { self?.tick() }
        }
        report()
    }

    /// The setting changed.
    func refresh() {
        report()
    }

    private var secondsSinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Whether the person is using the Mac now.
    var isInUse: Bool {
        guard isEnabled(), !isLocked, !isAsleep else { return false }
        return secondsSinceInput < Self.idleThreshold
    }

    /// A late timer means the app was napping after all; the log says by how much.
    private func tick() {
        let now = Date()
        if let lastTick, !isLocked, !isAsleep, isEnabled() {
            let gap = now.timeIntervalSince(lastTick)
            if gap > MacPresenceRecordSchema.interval * 2 {
                SafeDiagnosticLog.shared.record("presence: check ran \(Int(gap)) s after the last")
            }
        }
        lastTick = now
        report()
    }

    /// App Nap stays off while there is someone to report on.
    private func updateActivity() {
        let wanted = isEnabled() && !isLocked && !isAsleep
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Telling the iPhone whether you're using this Mac"
            )
        } else if !wanted, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// In use: written each time, so the iPhone sees a fresh time. Away: written once,
    /// with when input last came, so the iPhone's log can say how long ago.
    private func report() {
        updateActivity()
        let idle = secondsSinceInput
        let inUse = isInUse
        guard inUse || lastWritten != false, let database else { return }
        if inUse != lastWritten {
            SafeDiagnosticLog.shared.record("presence: \(inUse ? "in use" : "away (\(awayReason(idle: idle)))")")
        }
        lastWritten = inUse
        let now = Date()
        let record = CKRecord(recordType: MacPresenceRecordSchema.recordType, recordID: CKRecord.ID(recordName: recordName))
        record[MacPresenceRecordSchema.isAtMac] = inUse ? 1 : 0
        record[MacPresenceRecordSchema.lastActiveAt] = inUse ? now : now.addingTimeInterval(-idle)
        record[MacPresenceRecordSchema.name] = Host.current().localizedName ?? "Mac"
        Task {
            do {
                // A record CloudKit refuses, as when its type isn't in the Production
                // schema, comes back in the results rather than as a thrown error.
                let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                if case .failure(let error)? = saved[record.recordID] { throw error }
                if !hasSaved {
                    hasSaved = true
                    SafeDiagnosticLog.shared.record("presence: saved to iCloud")
                }
            } catch {
                SafeDiagnosticLog.shared.record("presence: status failed: \(error.localizedDescription)")
                lastWritten = nil
            }
        }
    }

    private func awayReason(idle: TimeInterval) -> String {
        if !isEnabled() { return "turned off" }
        if isLocked { return "locked" }
        if isAsleep { return "asleep" }
        return "no input for \(Int(idle)) s"
    }
}
