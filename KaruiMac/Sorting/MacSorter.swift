import Foundation
import KaruiSorting

/// This Mac's own verdict on a notification, sorted with the iPhone's settings. Shown
/// in the inbox until the iPhone's verdict arrives; sent with a sort request, so the
/// iPhone files it instead of sorting again in the background.
struct MacVerdict: Codable, Equatable, Sendable {
    var category: String
    var reason: String
    var confidence: Double
    var interest: Int?
    /// `ClassificationEngine`'s raw value.
    var engine: String
    /// The rules stood in for the model; such a verdict stays here, and the iPhone sorts it.
    var isModelFallback: Bool

    init(_ result: TriageResult) {
        category = result.category.rawValue
        reason = result.reason
        confidence = result.confidence
        interest = result.interest
        engine = result.engine.rawValue
        isModelFallback = result.isModelFallback
    }
}

/// Sorts each notification as it arrives, with the iPhone's settings and Apple's
/// on-device model on this Mac, so the inbox has a category at once and the iPhone
/// needn't sort what only the Mac received. Then, when the iPhone's Second Opinion
/// setting calls for it, asks Private Cloud Compute through the person's Shortcut.
/// One at a time: the model answers one request at a time anyway.
@MainActor
final class MacSorter {
    private let settings: SortingSettingsStore
    private var queue: Task<Void, Never>?
    /// Checked now and then, not before each notification.
    private var shortcutCheck: (name: String, isInstalled: Bool, at: Date)?
    private var backoff = SecondOpinionBackoff()

    init(settings: SortingSettingsStore) {
        self.settings = settings
    }

    /// Whether this Mac can sort: macOS 26 or later, and the iPhone's settings here.
    var canSort: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return settings.policy != nil
    }

    /// `sorted` follows the verdict, for a banner during a Focus (`MacRepost`).
    func sort(itemID: String, in inbox: Inbox, shortcutName: String, sorted: @escaping @MainActor (String) -> Void = { _ in }) {
        guard #available(macOS 26.0, *), let policy = settings.policy,
              let item = inbox.item(id: itemID), item.macVerdict == nil else { return }
        let notification = NotificationInput.fromMac(
            app: item.app, title: item.title, subtitle: item.subtitle, body: item.body, receivedAt: item.deliveredAt
        )
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            var result = await FoundationModelClassifier(environment: .mac).classify(notification, policy: policy)
            if MacSecondOpinion.shouldAsk(about: result, policy: policy),
               self?.backoff.isPaused(at: Date()) == false,
               await self?.isShortcutInstalled(shortcutName) == true {
                if let cloud = await MacSecondOpinion.ask(about: notification, policy: policy, shortcutName: shortcutName, environment: .mac) {
                    result = cloud
                    if self?.backoff.recordAnswer() == true {
                        SafeDiagnosticLog.shared.record("second opinion: answering again, asking each time")
                    }
                } else if let pause = self?.backoff.recordFailure(at: Date()) {
                    SafeDiagnosticLog.shared.record("second opinion: paused for \(Int(pause / 60)) min after failing; the on-device model's answers stand")
                }
            }
            inbox.setMacVerdict(MacVerdict(result), id: itemID)
            sorted(itemID)
            SafeDiagnosticLog.shared.record("sorted here: \(item.app) \(result.category.rawValue) by \(result.engine.rawValue)\(result.isModelFallback ? " (rules stood in)" : "")")
        }
    }

    private func isShortcutInstalled(_ name: String) async -> Bool {
        if let check = shortcutCheck, check.name == name, Date().timeIntervalSince(check.at) < 10 * 60 {
            return check.isInstalled
        }
        let isInstalled = await MacSecondOpinion.isInstalled(name: name)
        shortcutCheck = (name, isInstalled, Date())
        return isInstalled
    }
}
