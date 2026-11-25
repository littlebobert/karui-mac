import Foundation
import KaruiLinkKit

/// During a Focus that lets Karui through (`MacFocusFiles`), or one with Karui's
/// filter, an Important notification from one of this Mac's apps, which the Focus
/// keeps quiet, comes again as Karui's own banner, as Karui does on the iPhone; not
/// from an app the Focus lets through too, whose own banner shows. Important by
/// whichever says so first, this Mac's sort or the iPhone's verdict; the iPhone's
/// verdict, which carries the person's corrections, has the last word, so a banner
/// it disagrees with goes.
enum MacRepost {
    /// Banners for notifications that arrived this recently: Karui catching up after
    /// a sleep isn't news.
    static let window: TimeInterval = 7 * 60
    /// With its own app in front the person most likely sees it there, so its banner
    /// waits this long for them to open it.
    static let holdWhileInFront: Duration = .seconds(10)
    /// How often a held banner looks for a read meanwhile.
    static let readCheckInterval: Duration = .seconds(2)

    enum Action: Equatable {
        case post
        /// From Notification Center: no longer Important, or read.
        case withdraw
        case none
    }

    /// What to do about this Mac's own notification, given whether a banner went
    /// already, whether a Focus Karui uses is on, and the apps that Focus lets through.
    static func action(for item: Inbox.Item, isFiltering: Bool, allowedApps: Set<String> = [], isPosted: Bool, now: Date = Date()) -> Action {
        guard item.id.hasPrefix("notification-") else { return .none }
        let isImportant = item.category == "notifyNow" && item.isUnread
        if isPosted { return isImportant ? .none : .withdraw }
        guard isFiltering, isImportant, now.timeIntervalSince(item.deliveredAt) < window else { return .none }
        let appIDs = KnownApp(rawValue: item.app)?.macBundleIdentifiers ?? []
        guard allowedApps.isDisjoint(with: appIDs) else { return .none }
        return .post
    }

    /// How long its banner waits for a read first: only while its own app is in front.
    /// Otherwise it goes at once, as a one-time code should.
    static func hold(for item: Inbox.Item, frontmostBundleID: String?) -> Duration {
        // Notification Center keeps some apps' IDs lowercased ("com.readdle.sparkdesktop"
        // for Spark's com.readdle.SparkDesktop), which is how Karui lists them.
        guard let frontmostBundleID, let app = KnownApp(rawValue: item.app),
              app.macBundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(frontmostBundleID) == .orderedSame })
        else { return .zero }
        return holdWhileInFront
    }

    /// The Focus is one Karui uses when it lets Karui through: otherwise its banners
    /// would be held too.
    static func isKaruisFocus(_ focus: ActiveFocus?, karuiID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let focus, let karuiID else { return false }
        return focus.allowedApps.contains(karuiID)
    }
}
