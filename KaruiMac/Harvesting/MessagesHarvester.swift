import Foundation
import KaruiLinkKit

/// A Messages notification carries the message's GUID, and Messages' own database
/// knows which chat that message is in and who is in it. iOS has no URL for one
/// message, so the link opens the conversation, as `ConversationRouter` in the
/// iPhone app does when it has everyone's number. Not yet tried against a real
/// chat.db; see Experiments/FINDINGS.md.
struct MessagesHarvester: NotificationHarvester {
    let bundleIdentifiers = Set(KnownApp.messages.macBundleIdentifiers)
    var chatDatabase = ChatDatabase.standard

    func harvest(_ record: NotificationRecord) async -> HarvestedLink? {
        guard let guid = record.userInfo["CKBBContextKeyMessageGUID"] ?? record.identifier else { return nil }
        do {
            let handles = try chatDatabase.handles(forMessageGUID: guid)
            guard let url = MessagesLink.url(handles: handles) else {
                SafeDiagnosticLog.shared.record("messages: no chat found for the notification")
                return nil
            }
            return HarvestedLink(
                link: record.deepLink(as: .messages, url: url, opensExactContent: true),
                readProbe: .messages(guid: guid),
                notificationID: record.id
            )
        } catch {
            SafeDiagnosticLog.shared.record("messages: chat.db read failed: \(error)")
            return nil
        }
    }

    func isRead(_ probe: ReadProbe) async -> Bool? {
        guard case .messages(let guid) = probe else { return nil }
        return try? chatDatabase.isRead(messageGUID: guid)
    }
}

enum MessagesLink {
    /// One person's thread by their number or address; a group by everyone in it,
    /// since a group has no address of its own.
    static func url(handles: [String]) -> URL? {
        switch handles.count {
        case 0: nil
        case 1: URL(string: "sms:\(handles[0])")
        default: URL(string: "sms://open?addresses=" + handles.joined(separator: ","))
        }
    }
}

/// Messages' `chat.db`, behind Full Disk Access like Notification Center's database.
struct ChatDatabase: Sendable {
    static let standard = ChatDatabase(
        url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
    )

    let url: URL

    /// The numbers and addresses of everyone in the chat holding the message, the
    /// user excepted (Messages doesn't list them).
    func handles(forMessageGUID guid: String) throws -> [String] {
        let database = try SQLiteDatabase.opening(url)
        let rows = try database.rows("""
            select handle.id from message
            join chat_message_join on chat_message_join.message_id = message.ROWID
            join chat_handle_join on chat_handle_join.chat_id = chat_message_join.chat_id
            join handle on handle.ROWID = chat_handle_join.handle_id
            where message.guid = ?1
            order by handle.id
            """, [.text(guid)])
        return rows.compactMap { $0[0].text }
    }

    /// How far from the iPhone's notification a message can be and still be its.
    static let matchWindow: TimeInterval = 10 * 60

    /// Whether the incoming message the iPhone's notification was for is read, found by
    /// its text near that time: nil when there's no such message. For a notification
    /// only the iPhone got, as when its conversation was open here and macOS posted
    /// nothing. Its text may be cut short and end in "…", so the start is compared.
    func isRead(text: String, near date: Date) throws -> Bool? {
        var start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while start.hasSuffix("…") || start.hasSuffix("...") {
            start = String(start.dropLast(start.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces)
        }
        start = String(start.prefix(60))
        guard !start.isEmpty else { return nil }
        let center = Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
        let window = Int64(Self.matchWindow * 1_000_000_000)
        let database = try SQLiteDatabase.opening(url)
        let rows = try database.rows("""
            select is_read from message
            where is_from_me = 0 and date between ?1 and ?2 and substr(text, 1, ?3) = ?4
            order by abs(date - ?5) limit 1
            """, [.integer(center - window), .integer(center + window), .integer(Int64(start.count)), .text(start), .integer(center)])
        guard let isRead = rows.first?[0].integer else { return nil }
        return isRead != 0
    }

    /// Messages marks a message read once its chat is opened, on any device.
    func isRead(messageGUID guid: String) throws -> Bool? {
        let database = try SQLiteDatabase.opening(url)
        let rows = try database.rows("select is_read from message where guid = ?1", [.text(guid)])
        guard let isRead = rows.first?[0].integer else { return nil }
        return isRead != 0
    }
}
