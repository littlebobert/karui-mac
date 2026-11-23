import CloudKit
import XCTest
@testable import KaruiMac
import KaruiLinkKit

/// A link another Mac sent, read back here for an item this Mac has none for.
final class OtherMacLinkTests: XCTestCase {
    private let delivered = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(url: String?, deliveredAt: Date?, exact: Int = 1) -> CKRecord {
        let record = CKRecord(recordType: DeepLinkRecordSchema.recordType, recordID: CKRecord.ID(recordName: "abc"))
        record[DeepLinkRecordSchema.app] = "Slack"
        record.encryptedValues[DeepLinkRecordSchema.url] = url
        record[DeepLinkRecordSchema.opensExactContent] = exact
        record[DeepLinkRecordSchema.deliveredAt] = deliveredAt
        record[DeepLinkRecordSchema.readAt] = delivered.addingTimeInterval(60)
        return record
    }

    func testReadsTheRecordAnotherMacWrote() throws {
        let url = "https://example.slack.com/archives/C01/p1795406082878579"
        let link = try XCTUnwrap(DeepLinkSync.link(from: record(url: url, deliveredAt: delivered), fingerprint: "abc"))
        XCTAssertEqual(link.url.absoluteString, url)
        XCTAssertEqual(link.app, "Slack")
        XCTAssertTrue(link.opensExactContent)
        XCTAssertEqual(link.deliveredAt, delivered)
        XCTAssertEqual(link.readAt, delivered.addingTimeInterval(60))
        XCTAssertEqual(link.fingerprint, "abc")
    }

    func testIncompleteRecordsGiveNoLink() {
        XCTAssertNil(DeepLinkSync.link(from: record(url: nil, deliveredAt: delivered), fingerprint: "abc"))
        XCTAssertNil(DeepLinkSync.link(from: record(url: "readdle-spark://bl=x", deliveredAt: nil), fingerprint: "abc"))
    }

    func testOnlyALinkFromAboutTheSameTimeIsTheSameNotification() {
        let link = DeepLinkRecord(fingerprint: "abc", app: "Spark", url: URL(string: "readdle-spark://bl=x")!,
                                  opensExactContent: true, deliveredAt: delivered)
        XCTAssertTrue(DeepLinkSync.isSameDelivery(link, as: delivered.addingTimeInterval(5 * 60)))
        XCTAssertTrue(DeepLinkSync.isSameDelivery(link, as: delivered.addingTimeInterval(-10 * 60)))
        XCTAssertFalse(DeepLinkSync.isSameDelivery(link, as: delivered.addingTimeInterval(2 * 60 * 60)), "the same words, hours later")
    }
}
