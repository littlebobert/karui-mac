import AppKit
import Foundation
import UserNotifications

/// This Mac's own banners for Important notifications only the iPhone received,
/// while the person is using the Mac and Karui on the iPhone alerts quietly
/// (`MacPresenceReporter`). A click opens the notification in the inbox.
@MainActor
final class MacBanners: NSObject, UNUserNotificationCenterDelegate {
    /// How long a verdict waits before its banner, in case this Mac's own copy of
    /// the notification arrives and takes its place, with the app's own banner.
    static let settleDelay: Duration = .seconds(15)
    /// Verdicts sorted longer ago than this are caught up, not news: no banner. Short:
    /// a verdict that reaches this Mac late is most often for something already read in
    /// its app here, and what's still unread reaches the iPhone as the person leaves
    /// (`HeldReleaseSender`).
    static let freshness: TimeInterval = 2 * 60
    private nonisolated static let itemIDKey = "itemID"
    /// To find the item again under another ID, as when the iPhone's copy has merged
    /// into this Mac's since the banner went.
    private nonisolated static let fingerprintKey = "fingerprint"
    private let center = UNUserNotificationCenter.current()
    var open: (_ id: String, _ fingerprint: String?) -> Void = { _, _ in }

    func start() {
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                SafeDiagnosticLog.shared.record("banners: permission failed: \(error.localizedDescription)")
            } else if !granted {
                SafeDiagnosticLog.shared.record("banners: not allowed")
            }
        }
    }

    func post(_ item: Inbox.Item) {
        let content = UNMutableNotificationContent()
        content.title = item.sender.isEmpty ? item.app : item.sender
        content.subtitle = [item.app, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = item.body ?? ""
        content.sound = .default
        content.threadIdentifier = item.conversation.key
        content.userInfo = [Self.itemIDKey: item.id, Self.fingerprintKey: item.fingerprint]
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil)) { error in
            if let error { SafeDiagnosticLog.shared.record("banners: post failed: \(error.localizedDescription)") }
        }
        SafeDiagnosticLog.shared.record("banners: posted one from \(item.app)")
    }

    /// Notifications were allowed or refused, and the Dock badge with them was turned
    /// off: macOS then hides the badge, so Settings says where to turn it on.
    func badgesAreBlocked() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus != .notDetermined && settings.badgeSetting != .enabled
    }

    /// Read here or elsewhere: its banner goes from Notification Center too.
    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let id = userInfo[Self.itemIDKey] as? String else { return }
        let fingerprint = userInfo[Self.fingerprintKey] as? String
        await MainActor.run { open(id, fingerprint) }
    }
}
