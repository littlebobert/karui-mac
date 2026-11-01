import SQLite3
import XCTest
@testable import KaruiMac

final class MessagesLinkTests: XCTestCase {
    func testOnePersonOpensTheirThread() {
        XCTAssertEqual(MessagesLink.url(handles: ["+819012345678"])?.absoluteString, "sms:+819012345678")
        XCTAssertEqual(MessagesLink.url(handles: ["ada@example.com"])?.absoluteString, "sms:ada@example.com")
    }

    func testAGroupListsEveryone() {
        XCTAssertEqual(
            MessagesLink.url(handles: ["+819012345678", "ada@example.com"])?.absoluteString,
            "sms://open?addresses=+819012345678,ada@example.com"
        )
    }

    func testNoHandlesMeansNoLink() {
        XCTAssertNil(MessagesLink.url(handles: []))
    }

    func testAGroupWithAnIDOpensByIt() {
        XCTAssertEqual(
            MessagesLink.url(handles: ["+819012345678", "ada@example.com"], groupID: "ABC-123")?.absoluteString,
            "sms://open?groupid=ABC-123"
        )
        XCTAssertEqual(
            MessagesLink.url(handles: ["+819012345678", "ada@example.com"], groupID: "")?.absoluteString,
            "sms://open?addresses=+819012345678,ada@example.com"
        )
    }

    func testGroupIDComesOnlyFromGroupChats() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MessagesLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "chat.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            create table message (ROWID integer primary key, guid text);
            create table chat (ROWID integer primary key, group_id text, display_name text, style integer);
            create table chat_message_join (chat_id integer, message_id integer);
            insert into chat values (1, 'GROUP-ID', 'Family', 43), (2, 'ONE-TO-ONE-ID', '', 45);
            insert into message values (1, 'in-group'), (2, 'in-chat');
            insert into chat_message_join values (1, 1), (2, 2);
            """, nil, nil, nil), SQLITE_OK)
        let chat = ChatDatabase(url: url)
        XCTAssertEqual(try chat.groupID(forMessageGUID: "in-group"), "GROUP-ID")
        XCTAssertNil(try chat.groupID(forMessageGUID: "in-chat"))
        XCTAssertNil(try chat.groupID(forMessageGUID: "missing"))
        XCTAssertEqual(try chat.groupID(forChatNamed: "Family"), "GROUP-ID")
        XCTAssertNil(try chat.groupID(forChatNamed: "Nobody"))
    }
}
