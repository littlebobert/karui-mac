import CloudKit
import Foundation
import KaruiLinkKit

/// When the person leaves this Mac, what the iPhone held meanwhile and is still unread
/// goes to it as one alert push (`HeldReleaseRecordSchema`): it shows on the iPhone at
/// once, with what was read here cancelled, instead of whenever iCloud's silent push
/// gets round to waking it or the held alerts' fallback fires. With everything read,
/// a push of its own cancels them and shows nothing, as otherwise the fallback would
/// show what was read if the silent push was lost. Not while another Mac is in use,
/// since the person may have moved to it; that Mac sends it when they leave.
actor HeldReleaseSender {
    private let database: CKDatabase?
    private let companionID: String
    /// Sent already, by fingerprint, in case clearing a held mark didn't reach iCloud:
    /// the next departure doesn't send them again.
    private var released: [String: Date] = [:]
    /// Marked read here and not yet sent as a cancel push.
    private var pendingCancel: [String] = []
    private var cancelTask: Task<Void, Never>?

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        companionID: String = CompanionPresence.identifier()
    ) {
        database = container?.privateCloudDatabase
        self.companionID = companionID
    }

    /// What iCloud says of one held notification.
    struct Held: Equatable {
        let fingerprint: String
        /// Nil when the iPhone's verdict isn't on the record yet: held, so unread.
        var isUnread: Bool?
        var readAt: Date?
        var triagedAt: Date?
        var heldAt: Date?
    }

    /// How far back a held notification is looked for. Past the fallback's delay it has
    /// gone out on its own, and if it's read the iPhone should still remove it.
    static let lookback: TimeInterval = 24 * 60 * 60

    /// Unread, to show; read, here or on the iPhone, to cancel. Expired: unread, but its
    /// fallback has shown it already.
    static func plan(_ held: [Held], readHere: Set<String>, now: Date = Date()) -> (unread: [String], read: [String], expired: [String]) {
        var unread: [String] = []
        var read: [String] = []
        var expired: [String] = []
        for item in held {
            let readOnMac = item.readAt.flatMap { readAt in
                VerdictStore.current(readAt, triagedAt: item.triagedAt ?? readAt)
            } != nil
            if readHere.contains(item.fingerprint) || item.isUnread == false || readOnMac {
                read.append(item.fingerprint)
            } else if let heldAt = item.heldAt, now.timeIntervalSince(heldAt) >= HeldReleaseRecordSchema.window {
                expired.append(item.fingerprint)
            } else {
                unread.append(item.fingerprint)
            }
        }
        return (unread, read, expired)
    }

    /// `readHere`: fingerprints read in this Mac's inbox, which may not have reached
    /// iCloud yet.
    func send(readHere: Set<String>, now: Date = Date()) async {
        guard let database else { return }
        released = released.filter { now.timeIntervalSince($0.value) < Self.lookback }
        do {
            if try await isAnotherMacInUse(database, now: now) {
                SafeDiagnosticLog.shared.record("held release: another Mac in use, left to it")
                return
            }
            let held = try await heldVerdicts(database, now: now).filter { released[$0.fingerprint] == nil }
            guard !held.isEmpty else { return }
            let plan = Self.plan(held, readHere: readHere, now: now)
            let push: CKRecord?
            if !plan.unread.isEmpty {
                push = CKRecord(
                    recordType: HeldReleaseRecordSchema.recordType,
                    recordID: CKRecord.ID(recordName: HeldReleaseRecordSchema.recordName(companionID: companionID))
                )
                push?[HeldReleaseRecordSchema.releasedAt] = now
                push?[HeldReleaseRecordSchema.unread] = HeldReleaseRecordSchema.value(plan.unread)
                push?[HeldReleaseRecordSchema.read] = HeldReleaseRecordSchema.value(plan.read)
            } else if !plan.read.isEmpty {
                push = CKRecord(
                    recordType: HeldCancelRecordSchema.recordType,
                    recordID: CKRecord.ID(recordName: HeldCancelRecordSchema.recordName(companionID: companionID))
                )
                push?[HeldCancelRecordSchema.cancelledAt] = now
                push?[HeldCancelRecordSchema.read] = HeldReleaseRecordSchema.value(plan.read)
            } else {
                push = nil
            }
            // The held marks go, so another Mac, or this one next time, doesn't send them again.
            let handled = plan.unread + plan.read + plan.expired
            let cleared = handled.map { fingerprint -> CKRecord in
                let record = CKRecord(
                    recordType: VerdictRecordSchema.recordType,
                    recordID: CKRecord.ID(recordName: VerdictRecordSchema.recordName(fingerprint: fingerprint))
                )
                record[VerdictRecordSchema.heldAt] = nil
                return record
            }
            let (saved, _) = try await database.modifyRecords(saving: [push].compactMap { $0 } + cleared, deleting: [], savePolicy: .changedKeys)
            if let push, case .failure(let error)? = saved[push.recordID] { throw error }
            for fingerprint in handled { released[fingerprint] = now }
            SafeDiagnosticLog.shared.record("held release: sent, \(plan.unread.count) unread, \(plan.read.count) read, \(plan.expired.count) expired")
        } catch {
            SafeDiagnosticLog.shared.record("held release: failed: \(error.localizedDescription)")
        }
    }

    /// Marking several in a row sends one push.
    static let cancelBatchDelay: Duration = .seconds(2)
    /// What fits in a push, which carries the list; any others clear with the silent push.
    static let cancelLimit = 40

    /// The newest marks, each once.
    static func cancelList(_ fingerprints: [String]) -> [String] {
        var seen = Set<String>()
        let unique = fingerprints.reversed().filter { seen.insert($0).inserted }
        return Array(unique.prefix(cancelLimit).reversed())
    }

    /// Marked read here: the iPhone's alerts about these go within seconds, by the push
    /// that shows nothing, rather than whenever iCloud's silent push wakes it.
    func cancel(fingerprints: [String]) {
        guard database != nil, !fingerprints.isEmpty else { return }
        pendingCancel += fingerprints
        guard cancelTask == nil else { return }
        cancelTask = Task {
            try? await Task.sleep(for: Self.cancelBatchDelay)
            await sendPendingCancel()
        }
    }

    private func sendPendingCancel(now: Date = Date()) async {
        let read = Self.cancelList(pendingCancel)
        pendingCancel = []
        cancelTask = nil
        guard let database, !read.isEmpty else { return }
        let push = CKRecord(
            recordType: HeldCancelRecordSchema.recordType,
            recordID: CKRecord.ID(recordName: HeldCancelRecordSchema.recordName(companionID: companionID))
        )
        push[HeldCancelRecordSchema.cancelledAt] = now
        push[HeldCancelRecordSchema.read] = HeldReleaseRecordSchema.value(read)
        do {
            let (saved, _) = try await database.modifyRecords(saving: [push], deleting: [], savePolicy: .changedKeys)
            if case .failure(let error)? = saved[push.recordID] { throw error }
            SafeDiagnosticLog.shared.record("held release: marked read, cancel sent for \(read.count)")
        } catch {
            SafeDiagnosticLog.shared.record("held release: cancel failed: \(error.localizedDescription)")
        }
    }

    private func isAnotherMacInUse(_ database: CKDatabase, now: Date) async throws -> Bool {
        let query = CKQuery(
            recordType: MacPresenceRecordSchema.recordType,
            predicate: NSPredicate(
                format: "%K == 1 AND %K > %@",
                MacPresenceRecordSchema.isAtMac,
                MacPresenceRecordSchema.lastActiveAt,
                now.addingTimeInterval(-MacPresenceRecordSchema.freshness) as NSDate
            )
        )
        let (matches, _) = try await database.records(matching: query, desiredKeys: [MacPresenceRecordSchema.isAtMac], resultsLimit: 10)
        let own = "presence-" + companionID
        return matches.contains { id, _ in id.recordName != own }
    }

    private func heldVerdicts(_ database: CKDatabase, now: Date) async throws -> [Held] {
        let query = CKQuery(
            recordType: VerdictRecordSchema.recordType,
            predicate: NSPredicate(format: "%K > %@", VerdictRecordSchema.heldAt, now.addingTimeInterval(-Self.lookback) as NSDate)
        )
        let keys = [VerdictRecordSchema.isUnread, VerdictRecordSchema.readAt, VerdictRecordSchema.triagedAt, VerdictRecordSchema.heldAt]
        let (matches, _) = try await database.records(matching: query, desiredKeys: keys, resultsLimit: 100)
        return matches.compactMap { id, result -> Held? in
            guard let record = try? result.get(),
                  let fingerprint = VerdictRecordSchema.fingerprint(recordName: id.recordName) else { return nil }
            return Held(
                fingerprint: fingerprint,
                isUnread: (record[VerdictRecordSchema.isUnread] as? Int).map { $0 != 0 },
                readAt: record[VerdictRecordSchema.readAt] as? Date,
                triagedAt: record[VerdictRecordSchema.triagedAt] as? Date,
                heldAt: record[VerdictRecordSchema.heldAt] as? Date
            )
        }
    }
}
