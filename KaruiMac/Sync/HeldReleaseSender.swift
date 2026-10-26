import CloudKit
import Foundation
import KaruiLinkKit

/// When the person leaves this Mac, what the iPhone held meanwhile and is still unread
/// goes to it as one alert push (`HeldReleaseRecordSchema`): it shows on the iPhone at
/// once, with what was read here cancelled, instead of whenever iCloud's silent push
/// gets round to waking it or the held alerts' fallback fires. Not while another Mac
/// is in use, since the person may have moved to it; that Mac sends it when they leave.
actor HeldReleaseSender {
    private let database: CKDatabase?
    private let companionID: String
    /// Sent already, by fingerprint, in case clearing a held mark didn't reach iCloud:
    /// the next departure doesn't send them again.
    private var released: [String: Date] = [:]

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
    }

    /// Unread, to show; read, here or on the iPhone, to cancel.
    static func plan(_ held: [Held], readHere: Set<String>) -> (unread: [String], read: [String]) {
        var unread: [String] = []
        var read: [String] = []
        for item in held {
            let readOnMac = item.readAt.flatMap { readAt in
                VerdictStore.current(readAt, triagedAt: item.triagedAt ?? readAt)
            } != nil
            if readHere.contains(item.fingerprint) || item.isUnread == false || readOnMac {
                read.append(item.fingerprint)
            } else {
                unread.append(item.fingerprint)
            }
        }
        return (unread, read)
    }

    /// `readHere`: fingerprints read in this Mac's inbox, which may not have reached
    /// iCloud yet.
    func send(readHere: Set<String>, now: Date = Date()) async {
        guard let database else { return }
        released = released.filter { now.timeIntervalSince($0.value) < HeldReleaseRecordSchema.window }
        do {
            if try await isAnotherMacInUse(database, now: now) {
                SafeDiagnosticLog.shared.record("held release: another Mac in use, left to it")
                return
            }
            let held = try await heldVerdicts(database, now: now).filter { released[$0.fingerprint] == nil }
            guard !held.isEmpty else { return }
            let plan = Self.plan(held, readHere: readHere)
            guard !plan.unread.isEmpty else {
                // A push now would have nothing to show and show something anyway.
                SafeDiagnosticLog.shared.record("held release: \(plan.read.count) held, all read; nothing to send")
                return
            }
            let release = CKRecord(
                recordType: HeldReleaseRecordSchema.recordType,
                recordID: CKRecord.ID(recordName: HeldReleaseRecordSchema.recordName(companionID: companionID))
            )
            release[HeldReleaseRecordSchema.releasedAt] = now
            release[HeldReleaseRecordSchema.unread] = HeldReleaseRecordSchema.value(plan.unread)
            release[HeldReleaseRecordSchema.read] = HeldReleaseRecordSchema.value(plan.read)
            // The held marks go, so another Mac, or this one next time, doesn't send them again.
            let cleared = (plan.unread + plan.read).map { fingerprint -> CKRecord in
                let record = CKRecord(
                    recordType: VerdictRecordSchema.recordType,
                    recordID: CKRecord.ID(recordName: VerdictRecordSchema.recordName(fingerprint: fingerprint))
                )
                record[VerdictRecordSchema.heldAt] = nil
                return record
            }
            let (saved, _) = try await database.modifyRecords(saving: [release] + cleared, deleting: [], savePolicy: .changedKeys)
            if case .failure(let error)? = saved[release.recordID] { throw error }
            for fingerprint in plan.unread + plan.read { released[fingerprint] = now }
            SafeDiagnosticLog.shared.record("held release: sent, \(plan.unread.count) unread, \(plan.read.count) read")
        } catch {
            SafeDiagnosticLog.shared.record("held release: failed: \(error.localizedDescription)")
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
            predicate: NSPredicate(format: "%K > %@", VerdictRecordSchema.heldAt, now.addingTimeInterval(-HeldReleaseRecordSchema.window) as NSDate)
        )
        let keys = [VerdictRecordSchema.isUnread, VerdictRecordSchema.readAt, VerdictRecordSchema.triagedAt]
        let (matches, _) = try await database.records(matching: query, desiredKeys: keys, resultsLimit: 100)
        return matches.compactMap { id, result -> Held? in
            guard let record = try? result.get(),
                  let fingerprint = VerdictRecordSchema.fingerprint(recordName: id.recordName) else { return nil }
            return Held(
                fingerprint: fingerprint,
                isUnread: (record[VerdictRecordSchema.isUnread] as? Int).map { $0 != 0 },
                readAt: record[VerdictRecordSchema.readAt] as? Date,
                triagedAt: record[VerdictRecordSchema.triagedAt] as? Date
            )
        }
    }
}
