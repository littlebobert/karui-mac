import Foundation

/// The apps whose notifications the Mac can turn into links, by the name Karui's
/// Shortcut gives them on the iPhone and the bundle identifiers of their Mac apps.
/// LINE isn't one: its notifications identify nothing and its Mac data is encrypted.
public enum KnownApp: String, CaseIterable, Sendable {
    case messages = "Messages"
    case spark = "Spark"
    case slack = "Slack"

    /// Lowercased, as Notification Center's database stores them.
    public var macBundleIdentifiers: [String] {
        switch self {
        case .messages: ["com.apple.mobilesms", "com.apple.ichat"]
        case .spark: ["com.readdle.sparkdesktop"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        }
    }

    public init?(macBundleIdentifier: String) {
        let identifier = macBundleIdentifier.lowercased()
        guard let app = Self.allCases.first(where: { $0.macBundleIdentifiers.contains(identifier) }) else {
            return nil
        }
        self = app
    }
}
