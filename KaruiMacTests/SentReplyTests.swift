import SQLite3
import XCTest
@testable import KaruiMac
import KaruiLinkKit

/// What the person sent after a notification, in its Messages chat or Spark
/// conversation: what the iPhone judges a deadline reminder's task done by.
final class SentReplyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SentReplyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func execute(_ sql: String, in url: URL) {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }

    private struct Message {
        var text: String
        var offset: TimeInterval
        var fromMe = false
        var chat: Int64 = 1
        var reaction = false
    }

    private func chat(_ messages: [Message]) -> ChatDatabase {
        let url = folder.appending(path: "chat.db")
        var sql = """
            create table message (ROWID integer primary key, guid text, text text, attributedBody blob, date integer,
                is_from_me integer, associated_message_type integer);
            create table chat_message_join (chat_id integer, message_id integer);
            """
        for (index, message) in messages.enumerated() {
            let date = Int64((now.timeIntervalSinceReferenceDate + message.offset) * 1_000_000_000)
            sql += "insert into message values (\(index + 1), 'g\(index)', '\(message.text)', null, \(date), \(message.fromMe ? 1 : 0), \(message.reaction ? 2000 : 0));"
            sql += "insert into chat_message_join values (\(message.chat), \(index + 1));"
        }
        execute(sql, in: url)
        return ChatDatabase(url: url)
    }

    func testMessagesReplyInTheSameChatAfterTheMessage() throws {
        let chat = chat([
            Message(text: "Can you come to our wedding? RSVP by Friday", offset: 0),
            Message(text: "Hi from someone else", offset: 30, chat: 2),
            Message(text: "Not this one, another chat", offset: 60, fromMe: true, chat: 2),
            Message(text: "Let me check", offset: 120, fromMe: true),
            Message(text: "❤️", offset: 150, fromMe: true, reaction: true),
            Message(text: "Yes, we’ll both be there!", offset: 600, fromMe: true),
        ])
        let reply = try XCTUnwrap(chat.reply(toText: "Can you come to our wedding? RSVP by Friday", near: now))
        XCTAssertEqual(reply.text, "Let me check\nYes, we’ll both be there!", "every message since, oldest first; no reactions")
        XCTAssertEqual(reply.sentAt.timeIntervalSince(now), 600, accuracy: 0.001)
    }

    func testNoReplyYetOrNoMatchingMessage() throws {
        let chat = chat([
            Message(text: "Before the message", offset: -60, fromMe: true),
            Message(text: "Pay the invoice by Nov 30", offset: 0),
        ])
        XCTAssertNil(try chat.reply(toText: "Pay the invoice by Nov 30", near: now), "only what was sent after it counts")
        XCTAssertNil(try chat.reply(toText: "Something else entirely", near: now))
        XCTAssertNil(try chat.reply(toText: "Pay the invoice by Nov 30", near: now.addingTimeInterval(3 * 60 * 60)), "too far from the time")
    }

    func testMatchesANotificationCutShort() throws {
        let chat = chat([
            Message(text: "Please confirm whether you can make the meeting on Thursday afternoon at the office", offset: 0),
            Message(text: "Confirmed, see you then", offset: 60, fromMe: true),
        ])
        XCTAssertEqual(try chat.reply(toText: "Please confirm whether you can make the meeting on Thurs…", near: now)?.text, "Confirmed, see you then")
    }

    func testAPhotoAloneIsNoReply() throws {
        let chat = chat([
            Message(text: "Send me the form by tomorrow", offset: 0),
            Message(text: "\u{FFFC}", offset: 60, fromMe: true),
        ])
        XCTAssertNil(try chat.reply(toText: "Send me the form by tomorrow", near: now))
    }

    func testSparkReplyInTheSameConversation() throws {
        let url = folder.appending(path: "messages.sqlite")
        let received = now.timeIntervalSince1970
        execute("""
            create table messages (pk integer primary key, subject text, receivedDate real, inSent integer,
                conversationPk integer, shortBody text);
            insert into messages values (1, 'Invoice #2041', \(received), 0, 7, 'Please pay by Friday');
            insert into messages values (2, 'Re: Invoice #2041', \(received + 3600), 1, 7, 'Paid this morning, receipt attached.');
            insert into messages values (3, 'Something else', \(received + 60), 1, 8, 'Unrelated');
            """, in: url)
        let spark = SparkHarvester(databaseURL: url)
        let reply = try XCTUnwrap(spark.reply(toSubject: "Invoice #2041", near: now))
        XCTAssertEqual(reply.text, "Paid this morning, receipt attached.")
        XCTAssertEqual(reply.sentAt.timeIntervalSince(now), 3600, accuracy: 0.001)
        XCTAssertNil(spark.reply(toSubject: "Invoice #9999", near: now))
    }

    func testDecodesTextKeptOnlyInAttributedBody() {
        let text = "Yes, see you there"
        var bytes = Array("streamtyped\u{81}NSAttributedString\u{00}NSObject\u{00}NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B, UInt8(text.utf8.count)] + Array(text.utf8) + [0x86, 0x84]
        XCTAssertEqual(AttributedBodyText.decode(Data(bytes)), text)

        let long = String(repeating: "a", count: 300)
        var longBytes = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81, 0x2C, 0x01]
        longBytes += Array(long.utf8)
        XCTAssertEqual(AttributedBodyText.decode(Data(longBytes)), long, "0x81 and a two-byte length")

        XCTAssertNil(AttributedBodyText.decode(Data("no class name here".utf8)))
    }
}

/// Which replies go back to the iPhone: a newer one than it has, never the same again.
final class ReminderWatchReplyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func watch(repliedAt: Date?) -> ReminderWatchRecord {
        ReminderWatchRecord(
            reminderID: UUID(), app: "Messages", deliveredAt: now, expiresAt: now.addingTimeInterval(86_400),
            title: "Sam", subtitle: nil, body: "RSVP by Friday", repliedAt: repliedAt, replyText: nil
        )
    }

    func testSendsOnlyANewerReply() throws {
        let reply = try XCTUnwrap(SentReply(texts: ["Yes!"], sentAt: now.addingTimeInterval(60)))
        XCTAssertEqual(ReminderWatches.newReply(reply, over: watch(repliedAt: nil)), reply)
        XCTAssertNil(ReminderWatches.newReply(reply, over: watch(repliedAt: now.addingTimeInterval(60))), "already sent")
        XCTAssertEqual(ReminderWatches.newReply(reply, over: watch(repliedAt: now)), reply, "a later message since")
        XCTAssertNil(ReminderWatches.newReply(nil, over: watch(repliedAt: nil)))
    }

    func testLongRepliesAreCut() throws {
        let reply = try XCTUnwrap(SentReply(texts: [String(repeating: "x", count: 900)], sentAt: now))
        XCTAssertEqual(reply.text.count, SentReply.characterLimit)
    }
}
