import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let showsMenuBarItem = "showsMenuBarItem"
        static let showsDockIcon = "showsDockIcon"
        static let showsUnreadBadge = "showsUnreadBadge"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsMenuBarItem = defaults.bool(forKey: Key.showsMenuBarItem)
        showsDockIcon = defaults.object(forKey: Key.showsDockIcon) as? Bool ?? true
        showsUnreadBadge = defaults.object(forKey: Key.showsUnreadBadge) as? Bool ?? true
    }
}
