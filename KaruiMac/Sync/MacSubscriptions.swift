import CloudKit
import Foundation
import KaruiLinkKit

/// Pushes for what the iPhone changes, so the Mac hears at once instead of on its
/// next poll: a verdict sorted or changed (read, recategorized, deleted), and the
/// iPhone's sorting settings. A running Mac app gets CloudKit's silent pushes right
/// away; the polls stay, slower, for any that go missing.
actor MacSubscriptions {
    static let verdictsID = "mac-verdicts"
    static let settingsID = "mac-sorting-settings"
    /// Bumped when the set of subscriptions changes, so they're saved again.
    private static let savedKey = "subscriptions.saved.v1"

    private let database: CKDatabase?
    private let defaults: UserDefaults

    init(
        container: CKContainer? = CloudKitEntitlement.hasKaruiContainer
            ? CKContainer(identifier: DeepLinkSync.containerIdentifier) : nil,
        defaults: UserDefaults = .standard
    ) {
        database = container?.privateCloudDatabase
        self.defaults = defaults
    }

    func ensure() async {
        guard let database, !defaults.bool(forKey: Self.savedKey) else { return }
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        // Only answered verdicts have a sort time; the Mac's own requests don't wake it.
        let verdicts = CKQuerySubscription(
            recordType: VerdictRecordSchema.recordType,
            predicate: NSPredicate(format: "%K > %@", VerdictRecordSchema.triagedAt, Date.distantPast as NSDate),
            subscriptionID: Self.verdictsID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        verdicts.notificationInfo = info
        let settings = CKQuerySubscription(
            recordType: SortingSettingsRecordSchema.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.settingsID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        settings.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [verdicts, settings], deleting: [])
            defaults.set(true, forKey: Self.savedKey)
            SafeDiagnosticLog.shared.record("pushes: subscribed")
        } catch {
            // Tried again on the next launch; the polls carry on meanwhile.
            SafeDiagnosticLog.shared.record("pushes: subscription failed: \(error.localizedDescription)")
        }
    }

    enum Change: Sendable {
        case verdict(CKRecord.ID)
        case settings
    }

    /// What a remote notification says changed, when it's one of these.
    static func change(in userInfo: [AnyHashable: Any]) -> Change? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else {
            return nil
        }
        switch notification.subscriptionID {
        case verdictsID: return notification.recordID.map(Change.verdict)
        case settingsID: return .settings
        default: return nil
        }
    }
}
