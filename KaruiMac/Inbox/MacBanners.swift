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
    /// Verdicts sorted longer ago than this are caught up, not new: no banner.
    static let freshness: TimeInterval = 3 * 60
    private nonisolated static let itemIDKey = "itemID"
    private let center = UNUserNotificationCenter.current()
    var open: (String) -> Void = { _ in }

    func start() {
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
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
        content.userInfo = [Self.itemIDKey: item.id]
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil)) { error in
            if let error { SafeDiagnosticLog.shared.record("banners: post failed: \(error.localizedDescription)") }
        }
        SafeDiagnosticLog.shared.record("banners: posted one from \(item.app)")
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
        guard let id = response.notification.request.content.userInfo[Self.itemIDKey] as? String else { return }
        await MainActor.run { open(id) }
    }
}
