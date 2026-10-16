import Foundation

/// Recognizes the notification another device shows during a call ("Move Call to
/// This iPad"), which FaceTime and Phone re-post every few minutes while the call
/// goes on. Nothing was missed, so Triage Notification ignores it outright; the
/// classifiers and the repeated-sender rule also know it, for items already in
/// History from before and for anything that reaches them another way.
public enum CallHandoffDetector {
    /// iOS's wording. Only English is known for certain.
    private static let phrases = ["move call to this"]

    public static func isCallHandoff(source: String, title: String, body: String) -> Bool {
        guard CallBackApp(source: source) != nil else { return false }
        let text = "\(title)\n\(body)".lowercased()
        return phrases.contains { text.contains($0) }
    }

    public static func result(for notification: NotificationInput) -> TriageResult? {
        guard isCallHandoff(source: notification.source, title: notification.title, body: notification.body) else { return nil }
        return TriageResult(
            category: .summary,
            confidence: 1,
            reason: KaruiLocalization.string("A call in progress on another device."),
            engine: .deterministicRules,
            engineDetail: KaruiLocalization.string("Offers to move a call you are already on; nothing was missed.")
        )
    }
}
