import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let showsMenuBarItem = "showsMenuBarItem"
        static let showsDockIcon = "showsDockIcon"
        static let showsUnreadBadge = "showsUnreadBadge"
        static let asksIPhoneToSort = "asksIPhoneToSort"
    }

    private let defaults: UserDefaults

    var showsMenuBarItem: Bool {
        didSet {
            defaults.set(showsMenuBarItem, forKey: Key.showsMenuBarItem)
            // With neither icon there'd be no way back into the app short of launching it again.
            if !showsMenuBarItem, !showsDockIcon { showsDockIcon = true }
        }
    }

    var showsDockIcon: Bool {
        didSet {
            defaults.set(showsDockIcon, forKey: Key.showsDockIcon)
            if !showsDockIcon, !showsMenuBarItem { showsMenuBarItem = true }
        }
    }

    /// The unread count on the Dock icon and beside the menu bar item.
    var showsUnreadBadge: Bool {
        didSet { defaults.set(showsUnreadBadge, forKey: Key.showsUnreadBadge) }
    }

    /// Notifications only this Mac got go to the iPhone to sort, text and all; off
    /// until the person turns it on, since it's the one thing that sends text
    /// from this Mac.
    var asksIPhoneToSort: Bool {
        didSet { defaults.set(asksIPhoneToSort, forKey: Key.asksIPhoneToSort) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsMenuBarItem = defaults.bool(forKey: Key.showsMenuBarItem)
        showsDockIcon = defaults.object(forKey: Key.showsDockIcon) as? Bool ?? true
        showsUnreadBadge = defaults.object(forKey: Key.showsUnreadBadge) as? Bool ?? true
        asksIPhoneToSort = defaults.bool(forKey: Key.asksIPhoneToSort)
    }
}
