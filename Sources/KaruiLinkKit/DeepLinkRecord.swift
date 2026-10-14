import Foundation

/// What the Mac tells the iPhone about one notification: where it opens, never what
/// it said. The iPhone looks one up by fingerprint when a Karui alert is tapped.
public struct DeepLinkRecord: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public var fingerprint: String
    /// The app's name as Karui's Shortcut reports it: "Messages", "Spark", "Slack".
    public var app: String
    public var url: URL
    /// Whether `url` opens the exact email or message, or only its conversation.
    public var opensExactContent: Bool
    public var deliveredAt: Date
    public var expiresAt: Date

    public init(
        fingerprint: String,
        app: String,
        url: URL,
        opensExactContent: Bool,
        deliveredAt: Date,
        expiresAt: Date? = nil
    ) {
        self.fingerprint = fingerprint
        self.app = app
        self.url = url
        self.opensExactContent = opensExactContent
        self.deliveredAt = deliveredAt
        self.expiresAt = expiresAt ?? deliveredAt.addingTimeInterval(Self.lifetime)
    }
}

/// The CloudKit record the Mac writes and the iPhone reads, named once for both.
public enum DeepLinkRecordSchema {
    public static let recordType = "DeepLink"
    public static let fingerprint = "fingerprint"
    public static let app = "app"
    public static let url = "url"
    public static let opensExactContent = "opensExactContent"
    public static let deliveredAt = "deliveredAt"
    public static let expiresAt = "expiresAt"
}
