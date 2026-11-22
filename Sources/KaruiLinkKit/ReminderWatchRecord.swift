import Foundation

/// A deadline reminder the iPhone asks the Mac to keep an eye on: the notification it
/// came from, so the Mac can find the conversation, and once you've replied there,
/// what you sent. The iPhone writes one per open reminder about a Messages or Spark
/// notification and deletes it when the reminder is done or gone. The Mac adds the
/// reply; the iPhone decides whether it finishes the task.
///
/// Everything a person wrote, the notification and the reply, goes end-to-end
/// encrypted.
public struct ReminderWatchRecord: Codable, Equatable, Sendable {
    /// The reminder's id; the record's name is `recordName(reminderID:)`.
    public var reminderID: UUID
    /// `KnownApp` name: "Messages" or "Spark".
    public var app: String
    /// When the notification arrived, to find its message near that time.
    public var deliveredAt: Date
    /// After this the Mac stops looking: the end of the due day.
    public var expiresAt: Date
    public var title: String
    public var subtitle: String?
    public var body: String
    /// When the reply the Mac found was sent; nil until it finds one. A later reply
    /// replaces an earlier one.
    public var repliedAt: Date?
    public var replyText: String?

    public init(
        reminderID: UUID,
        app: String,
        deliveredAt: Date,
        expiresAt: Date,
        title: String,
        subtitle: String?,
        body: String,
        repliedAt: Date? = nil,
        replyText: String? = nil
    ) {
        self.reminderID = reminderID
        self.app = app
        self.deliveredAt = deliveredAt
        self.expiresAt = expiresAt
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.repliedAt = repliedAt
        self.replyText = replyText
    }

    /// The apps whose sent messages the Mac can read.
    public static let watchedApps: Set<String> = [KnownApp.messages.rawValue, KnownApp.spark.rawValue]

    private static let recordNamePrefix = "reminder-watch-"

    public static func recordName(reminderID: UUID) -> String {
        recordNamePrefix + reminderID.uuidString
    }

    public static func reminderID(recordName: String) -> UUID? {
        guard recordName.hasPrefix(recordNamePrefix) else { return nil }
        return UUID(uuidString: String(recordName.dropFirst(recordNamePrefix.count)))
    }
}

/// The CloudKit record both apps read and write, named once for both.
public enum ReminderWatchRecordSchema {
    public static let recordType = "ReminderWatch"
    public static let app = "app"
    public static let deliveredAt = "deliveredAt"
    public static let expiresAt = "expiresAt"
    /// Encrypted.
    public static let title = "title"
    /// Encrypted.
    public static let subtitle = "subtitle"
    /// Encrypted.
    public static let body = "body"
    public static let repliedAt = "repliedAt"
    /// Encrypted.
    public static let replyText = "replyText"
}
