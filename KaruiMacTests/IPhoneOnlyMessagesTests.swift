import SQLite3
import XCTest
@testable import KaruiMac

/// A message only the iPhone's notification brought here, found in Messages' database
/// by its text and time, read once Messages says so.
final class IPhoneOnlyMessagesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "IPhoneOnlyMessagesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// chat.db's message table, with these messages: text, seconds from `now`, from
    /// me or not, read or not.
    private func chat(_ messages: [(text: String, offset: TimeInterval, fromMe: Bool, read: Bool)]) throws -> ChatDatabase {
        let url = folder.appending(path: "chat.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var sql = "create table message (ROWID integer primary key, guid text, text text, date integer, is_from_me integer, is_read integer);"
        for (index, message) in messages.enumerated() {
            let date = Int64((now.timeIntervalSinceReferenceDate + message.offset) * 1_000_000_000)
            sql += "insert into message values (\(index + 1), 'g\(index)', '\(message.text)', \(date), \(message.fromMe ? 1 : 0), \(message.read ? 1 : 0));"
        }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return ChatDatabase(url: url)
    }

    func testFoundByTextNearTheTime() throws {
        let chat = try chat([
            ("Home now", -20, false, true),
            ("Home now", -3 * 60 * 60, false, false),
            ("Running late, sorry about that, see you at the station in ten", 5, false, false),
        ])
        XCTAssertEqual(try chat.isRead(text: "Home now", near: now), true, "the one near the time, not this morning's")
        XCTAssertEqual(try chat.isRead(text: "Running late, sorry about that…", near: now), false, "cut short with an ellipsis")
        XCTAssertNil(try chat.isRead(text: "Something else", near: now))
        XCTAssertNil(try chat.isRead(text: "Home now", near: now.addingTimeInterval(2 * 60 * 60)), "too far from the time")
    }

    func testOnlyIncoming() throws {
        let chat = try chat([("On my way", 0, true, true)])
        XCTAssertNil(try chat.isRead(text: "On my way", near: now), "one I sent isn't the notification's")
    }
}
