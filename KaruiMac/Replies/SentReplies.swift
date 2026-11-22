import Foundation
import KaruiLinkKit

/// What the person sent in a conversation after a notification from it: every
/// message since, oldest first, as one text, and when the last one went.
struct SentReply: Equatable, Sendable {
    let text: String
    let sentAt: Date

    /// Enough for the iPhone to judge a reply by; a long email is cut.
    static let characterLimit = 600

    /// Several messages, oldest first, one a line, cut to `characterLimit`. Nil when
    /// none has any text, as with a photo on its own.
    init?(texts: [String], sentAt: Date) {
        let lines = texts
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        text = String(lines.joined(separator: "\n").prefix(Self.characterLimit))
        self.sentAt = sentAt
    }
}

extension ChatDatabase {
    /// What the person sent in the chat holding the incoming message the iPhone's
    /// notification was for, after it: found by its text near that time, as for
    /// `isRead(text:near:)`. Tapbacks and other reactions aren't replies.
    func reply(toText text: String, near date: Date) throws -> SentReply? {
        let start = Self.comparableStart(of: text)
        guard !start.isEmpty else { return nil }
        let center = Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
        let window = Int64(Self.matchWindow * 1_000_000_000)
        let database = try SQLiteDatabase.opening(url)
        // Compared here rather than in SQL: a message's text can be only in
        // `attributedBody`.
        let incoming = try database.rows("""
            select message.date, message.text, message.attributedBody, chat_message_join.chat_id from message
            join chat_message_join on chat_message_join.message_id = message.ROWID
            where message.is_from_me = 0 and message.date between ?1 and ?2
            order by abs(message.date - ?3)
            """, [.integer(center - window), .integer(center + window), .integer(center)])
        guard let match = incoming.first(where: { row in
            let body = row[1].text ?? row[2].blob.flatMap(AttributedBodyText.decode) ?? ""
            return Self.comparableStart(of: body).hasPrefix(start)
        }), let received = match[0].integer, let chat = match[3].integer else { return nil }

        let sent = try database.rows("""
            select message.date, message.text, message.attributedBody from message
            join chat_message_join on chat_message_join.message_id = message.ROWID
            where chat_message_join.chat_id = ?1 and message.is_from_me = 1 and message.date > ?2
              and coalesce(message.associated_message_type, 0) = 0
            order by message.date
            """, [.integer(chat), .integer(received)])
        guard let last = sent.last?[0].integer else { return nil }
        let texts = sent.map { $0[1].text ?? $0[2].blob.flatMap(AttributedBodyText.decode) ?? "" }
        return SentReply(texts: texts, sentAt: Date(timeIntervalSinceReferenceDate: TimeInterval(last) / 1_000_000_000))
    }

    /// The start of a message as a notification shows it: without a trailing "…",
    /// at most 60 characters, so a notification cut short still matches.
    static func comparableStart(of text: String) -> String {
        var start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while start.hasSuffix("…") || start.hasSuffix("...") {
            start = String(start.dropLast(start.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces)
        }
        return String(start.prefix(60))
    }
}

extension SparkHarvester {
    /// What the person sent in the email's conversation after it arrived, from the
    /// previews Spark keeps of sent mail. The email is found by subject near the
    /// time, as for its link.
    func reply(toSubject subject: String, near date: Date) -> SentReply? {
        guard !subject.isEmpty else { return nil }
        let time = date.timeIntervalSince1970
        do {
            let database = try SQLiteDatabase.opening(databaseURL)
            let incoming = try database.rows("""
                select conversationPk, receivedDate from messages
                where receivedDate between ?2 and ?3 and subject = ?1 and coalesce(inSent, 0) = 0
                order by abs(receivedDate - ?4)
                limit 1
                """, [.text(subject), .real(time - Self.lookBack), .real(time + Self.lookAhead), .real(time)])
            guard let row = incoming.first, let conversation = row[0].integer, let received = row[1].real else { return nil }
            let sent = try database.rows("""
                select shortBody, receivedDate from messages
                where conversationPk = ?1 and inSent = 1 and receivedDate > ?2
                order by receivedDate
                """, [.integer(conversation), .real(received)])
            guard let last = sent.last?[1].real else { return nil }
            return SentReply(texts: sent.map { $0[0].text ?? "" }, sentAt: Date(timeIntervalSince1970: last))
        } catch {
            SafeDiagnosticLog.shared.record("spark: reading sent mail failed: \(error)")
            return nil
        }
    }
}

/// The text of a message Messages stored only as an archived attributed string
/// (`attributedBody`), as it does for some: the string follows the `NSString` class
/// name, after a `+` and its length (one byte, or 0x81 and two bytes, or 0x82 and
/// four, little-endian).
enum AttributedBodyText {
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let classEnd = bytes.firstRange(of: Array("NSString".utf8))?.upperBound else { return nil }
        guard let plus = bytes[classEnd..<min(classEnd + 12, bytes.count)].firstIndex(of: 0x2B),
              plus + 1 < bytes.count else { return nil }
        var position = plus + 2
        var length = Int(bytes[plus + 1])
        func littleEndian(_ count: Int) -> Int? {
            guard position + count <= bytes.count else { return nil }
            let value = bytes[position..<position + count].reversed().reduce(0) { $0 << 8 | Int($1) }
            position += count
            return value
        }
        if length == 0x81 {
            guard let value = littleEndian(2) else { return nil }
            length = value
        } else if length == 0x82 {
            guard let value = littleEndian(4) else { return nil }
            length = value
        }
        guard length > 0, position + length <= bytes.count else { return nil }
        return String(bytes: bytes[position..<position + length], encoding: .utf8)
    }
}
