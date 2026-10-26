import Foundation

/// During a Focus with Karui's filter, an Important notification from one of this
/// Mac's apps, which the Focus keeps quiet, comes again as Karui's own banner, as
/// Karui does on the iPhone. Important by whichever says so first, this Mac's sort
/// or the iPhone's verdict; the iPhone's verdict, which carries the person's
/// corrections, has the last word, so a banner it disagrees with goes.
enum MacRepost {
    /// Banners for notifications that arrived this recently: Karui catching up after
    /// a sleep isn't news.
    static let window: TimeInterval = 7 * 60

    enum Action: Equatable {
        case post
        /// From Notification Center: no longer Important, or read.
        case withdraw
        case none
    }

    /// What to do about this Mac's own notification, given whether a banner went
    /// already and whether the Focus's filter is on.
    static func action(for item: Inbox.Item, isFiltering: Bool, isPosted: Bool, now: Date = Date()) -> Action {
        guard item.id.hasPrefix("notification-") else { return .none }
        let isImportant = item.category == "notifyNow" && item.isUnread
        if isPosted { return isImportant ? .none : .withdraw }
        guard isFiltering, isImportant, now.timeIntervalSince(item.deliveredAt) < window else { return .none }
        return .post
    }
}
