import CloudKit
import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A link's record on iCloud is named by the fingerprint, which is the app and the
/// text with no time in it, so a second "Verify your email" from one sender found
/// the first one's record, read the day before (2026-11-27). The Mac took the record
/// as it was: the new email was read on arrival, nothing watched for it being read
/// here, and the iPhone's alert about it stayed.
@MainActor
final class RepeatedLinkTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func link(at date: Date, url: String = "readdle-spark://bl=today") -> DeepLinkRecord {
        DeepLinkRecord(fingerprint: "abc", app: "Spark", url: URL(string: url)!, opensExactContent: true, deliveredAt: date)
    }

    private func record(deliveredAt: Date?, readAt: Date?) -> CKRecord {
        let record = CKRecord(recordType: DeepLinkRecordSchema.recordType, recordID: CKRecord.ID(recordName: "abc"))
        record[DeepLinkRecordSchema.app] = "Spark"
        record.encryptedValues[DeepLinkRecordSchema.url] = "readdle-spark://bl=yesterday"
        record[DeepLinkRecordSchema.opensExactContent] = 1
        record[DeepLinkRecordSchema.deliveredAt] = deliveredAt
        record[DeepLinkRecordSchema.expiresAt] = deliveredAt?.addingTimeInterval(day)
        record[DeepLinkRecordSchema.readAt] = readAt
        return record
    }

    func testARecordFromWellBeforeIsAnEarlierNotifications() {
        let yesterdays = record(deliveredAt: today.addingTimeInterval(-day), readAt: today.addingTimeInterval(-day + 13))
        XCTAssertTrue(DeepLinkSync.isEarlierNotification(yesterdays, than: link(at: today)))
        // Four hours earlier the same day, as the second and third copies were.
        XCTAssertTrue(DeepLinkSync.isEarlierNotification(record(deliveredAt: today.addingTimeInterval(-4 * 3600), readAt: nil), than: link(at: today)))
        // A record with no time can't be this notification's.
        XCTAssertTrue(DeepLinkSync.isEarlierNotification(record(deliveredAt: nil, readAt: nil), than: link(at: today)))
    }

    func testTheSameNotificationFromAnotherMacIsLeftAsItIs() {
        // The other Mac got it a few minutes sooner, and it was read there since.
        let otherMacs = record(deliveredAt: today.addingTimeInterval(-5 * 60), readAt: today.addingTimeInterval(-60))
        XCTAssertFalse(DeepLinkSync.isEarlierNotification(otherMacs, than: link(at: today)))
        // An old notification harvested late doesn't take over a newer one's record.
        let newer = record(deliveredAt: today.addingTimeInterval(day), readAt: nil)
        XCTAssertFalse(DeepLinkSync.isEarlierNotification(newer, than: link(at: today)))
    }

    func testTakingARecordOverLeavesNoReadMark() throws {
        let yesterdays = record(deliveredAt: today.addingTimeInterval(-day), readAt: today.addingTimeInterval(-day + 13))
        DeepLinkSync.fill(yesterdays, with: link(at: today))
        let taken = try XCTUnwrap(DeepLinkSync.link(from: yesterdays, fingerprint: "abc"))
        XCTAssertNil(taken.readAt)
        XCTAssertEqual(taken.deliveredAt, today)
        XCTAssertEqual(taken.expiresAt, today.addingTimeInterval(DeepLinkRecord.lifetime))
        // The iPhone opens today's email, not yesterday's.
        XCTAssertEqual(taken.url.absoluteString, "readdle-spark://bl=today")
    }

    func testAnEarlierReadMarkDoesNotReadWhatArrivedLater() {
        let suite = "RepeatedLinkTests.\(UUID().uuidString)"
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        func email(_ id: Int64, at date: Date) -> NotificationRecord {
            NotificationRecord(
                id: id, bundleIdentifier: "com.readdle.sparkdesktop", deliveredAt: date,
                title: "ElevenLabs", subtitle: "Verify your email", body: "Verify your email address.", identifier: nil, userInfo: [:]
            )
        }
        inbox.add(email(1, at: today.addingTimeInterval(-day)), as: .spark)
        inbox.add(email(2, at: today), as: .spark)
        let fingerprint = Inbox.fingerprint(for: email(2, at: today), as: .spark)
        var told: [Set<String>] = []
        inbox.onRead = { told.append($0) }

        // Yesterday's read mark, as the record on iCloud carried it.
        let readYesterday = today.addingTimeInterval(-day + 13)
        inbox.markRead(fingerprint: fingerprint, at: readYesterday)
        XCTAssertEqual(inbox.item(id: "notification-1")?.readAt, readYesterday)
        XCTAssertNil(inbox.item(id: "notification-2")?.readAt, "today's arrived a day after that mark")
        XCTAssertEqual(told, [["notification-1"]], "and the iPhone isn't told to drop its alert about today's")

        // Read now, both are.
        inbox.markRead(fingerprint: fingerprint, at: today.addingTimeInterval(120))
        XCTAssertNotNil(inbox.item(id: "notification-2")?.readAt)
        XCTAssertEqual(told.last, ["notification-1", "notification-2"])

        // A mark from another Mac that got it a little sooner still counts.
        inbox.add(email(3, at: today.addingTimeInterval(3600)), as: .spark)
        inbox.markRead(fingerprint: fingerprint, at: today.addingTimeInterval(3600 - 5 * 60))
        XCTAssertNotNil(inbox.item(id: "notification-3")?.readAt)
    }
}
