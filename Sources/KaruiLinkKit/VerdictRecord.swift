import Foundation

/// Karui's judgment of one notification, from the iPhone to the Mac, named by the
/// fingerprint like the link: the Mac already has the notification's text from
/// Notification Center and joins the two. Text fields are only for notifications
/// from apps the Mac doesn't have, and only when the person asks for that.
///
/// The same record type carries the Mac's request to sort a notification the
/// iPhone never got (`sortRequestedAt`); until the iPhone answers it has no
/// category, so it isn't a verdict yet.
public struct VerdictRecord: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public var fingerprint: String
    public var app: String
    /// Karui's category raw value: `notifyNow`, `summary`, or `silence`.
    public var category: String
    public var interest: Int?
    public var reason: String
    public var triagedAt: Date
    public var isUnread: Bool
    public var title: String?
    public var body: String?
    /// The rest of the notification, for grouping threads the way the iPhone does:
    /// the subtitle, the sender, and the recipients the Shortcut listed.
    public var subtitle: String?
    public var sender: String?
    public var recipients: String?
    /// Set by the Mac: read there, a category the person chose there, or deleted
    /// there. The iPhone applies them to History and clears them on its next send.
    public var readAt: Date?
    public var requestedCategory: String?
    public var deletedAt: Date?

    public init(
        fingerprint: String,
        app: String,
        category: String,
        interest: Int?,
        reason: String,
        triagedAt: Date,
        isUnread: Bool,
        title: String? = nil,
        body: String? = nil,
        readAt: Date? = nil,
        requestedCategory: String? = nil,
        deletedAt: Date? = nil,
        subtitle: String? = nil,
        sender: String? = nil,
        recipients: String? = nil
    ) {
        self.subtitle = subtitle
        self.sender = sender
        self.recipients = recipients
        self.fingerprint = fingerprint
        self.app = app
        self.category = category
        self.interest = interest
        self.reason = reason
        self.triagedAt = triagedAt
        self.isUnread = isUnread
        self.title = title
        self.body = body
        self.readAt = readAt
        self.requestedCategory = requestedCategory
        self.deletedAt = deletedAt
    }
}

public enum VerdictRecordSchema {
    public static let recordType = "Verdict"
    /// Record names are unique across types in a zone, and the link's record is
    /// named by the bare fingerprint; the verdict's carries this prefix.
    public static let recordNamePrefix = "verdict-"

    public static func recordName(fingerprint: String) -> String { recordNamePrefix + fingerprint }

    public static func fingerprint(recordName: String) -> String? {
        guard recordName.hasPrefix(recordNamePrefix) else { return nil }
        return String(recordName.dropFirst(recordNamePrefix.count))
    }
    public static let app = "app"
    public static let category = "category"
    public static let interest = "interest"
    /// Encrypted: it paraphrases the message.
    public static let reason = "reason"
    public static let triagedAt = "triagedAt"
    public static let isUnread = "isUnread"
    /// Encrypted, and only for apps the Mac doesn't have.
    public static let title = "title"
    public static let body = "body"
    public static let subtitle = "subtitle"
    public static let sender = "sender"
    public static let recipients = "recipients"
    public static let readAt = "readAt"
    public static let requestedCategory = "requestedCategory"
    public static let deletedAt = "deletedAt"
    /// When the Mac last did any of the three; what the iPhone subscribes to.
    public static let actionAt = "actionAt"

    /// Set by the Mac on a record it creates for a notification only it got, which
    /// carries the text and no category: the iPhone sorts it and writes its verdict
    /// onto the same record. What the iPhone's second subscription watches.
    public static let sortRequestedAt = "sortRequestedAt"
    /// When a notification the Mac asks about arrived there. The iPhone files it at
    /// that time, so its verdict goes with the Mac's notification.
    public static let deliveredAt = "deliveredAt"
}
