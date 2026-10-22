import KaruiLinkKit
import SQLite3
import XCTest
@testable import KaruiMac

final class SparkHarvestTests: XCTestCase {
    private var folder: URL!
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SparkHarvestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database shaped like Spark's, with these emails: subject and seconds from `now`.
    private func spark(_ emails: [(subject: String, offset: TimeInterval)]) throws -> SparkHarvester {
        let url = folder.appending(path: "messages.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var sql = """
            create table accounts (pk integer primary key, additionalInfo text);
            insert into accounts values (1, '{"accountAddress":"me@example.com"}');
            create table messages (pk integer primary key, accountPk integer, subject text, receivedDate integer,
                messageId text, gmailMessageId text, unseen integer);
            create index messages_index_received_date on messages (receivedDate desc, pk, accountPk);
            """
        for (index, email) in emails.enumerated() {
            let received = Int(now.timeIntervalSince1970 + email.offset)
            sql += "insert into messages values (\(index + 1), 1, '\(email.subject)', \(received), '<m\(index + 1)@example.com>', '0', 1);"
        }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return SparkHarvester(databaseURL: url)
    }

    /// An email Spark announced late, after the Mac woke, is still found, and its
    /// link is dated when it arrived, which is when the iPhone notified.
    func testALateNotificationFindsItsEmailDatedWhenItArrived() throws {
        let harvester = try spark([("Invoice", -40 * 60), ("Invoice", -3 * 60 * 60)])
        let email = try XCTUnwrap(harvester.email(subject: "Invoice", near: now))
        XCTAssertEqual(email.receivedAt, now.addingTimeInterval(-40 * 60))
        XCTAssertEqual(email.primaryKey, 1)
        XCTAssertNil(harvester.email(subject: "Invoice", near: now.addingTimeInterval(-6 * 60 * 60 + 20 * 60)), "beyond the look-back")
        XCTAssertNil(harvester.email(subject: "Receipt", near: now))
    }

    /// The nearest email of that subject wins, and one from the future only by a little.
    func testTheNearestEmailWins() throws {
        let harvester = try spark([("Your order", -90 * 60), ("Your order", -2 * 60), ("Your order", 10 * 60)])
        XCTAssertEqual(harvester.email(subject: "Your order", near: now)?.primaryKey, 2)
        XCTAssertEqual(harvester.email(subject: "Your order", near: now.addingTimeInterval(8 * 60))?.primaryKey, 3)
    }

    /// From the iPhone's verdict: named by the iPhone's fingerprint, exact, dated
    /// by the email, and with no Notification Center record behind it.
    func testALinkFromTheIPhonesVerdict() throws {
        let harvester = try spark([("Lunch?", -45)])
        let harvested = try XCTUnwrap(harvester.harvest(fingerprint: "abc", subject: "Lunch?", near: now))
        XCTAssertEqual(harvested.link.fingerprint, "abc")
        XCTAssertEqual(harvested.link.app, "Spark")
        XCTAssertTrue(harvested.link.opensExactContent)
        XCTAssertEqual(harvested.link.deliveredAt, now.addingTimeInterval(-45))
        XCTAssertTrue(harvested.link.url.absoluteString.hasPrefix("readdle-spark://bl="))
        XCTAssertNil(harvested.notificationID)
        XCTAssertEqual(harvested.readProbe, .spark(messagePrimaryKey: 1))
        XCTAssertNil(harvester.harvest(fingerprint: "abc", subject: "", near: now))
    }
}
