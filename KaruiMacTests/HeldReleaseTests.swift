import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// What a Mac tells the iPhone as the person leaves: held and unread is shown, held
/// and read anywhere is cancelled.
final class HeldReleaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnreadAndRead() {
        let held = [
            HeldReleaseSender.Held(fingerprint: "a", isUnread: true, readAt: nil, triagedAt: now),
            HeldReleaseSender.Held(fingerprint: "b", isUnread: nil, readAt: nil, triagedAt: nil),
            HeldReleaseSender.Held(fingerprint: "c", isUnread: false, readAt: nil, triagedAt: now),
            HeldReleaseSender.Held(fingerprint: "d", isUnread: true, readAt: now.addingTimeInterval(30), triagedAt: now),
            HeldReleaseSender.Held(fingerprint: "e", isUnread: true, readAt: nil, triagedAt: now),
        ]
        let plan = HeldReleaseSender.plan(held, readHere: ["e"])
        XCTAssertEqual(plan.unread, ["a", "b"], "no verdict yet counts as unread: it was held")
        XCTAssertEqual(plan.read, ["c", "d", "e"], "read on the iPhone, on a Mac, or here not yet in iCloud")
    }

    /// A read mark left from an earlier notification of the same fingerprint doesn't count.
    func testAStaleReadMarkIsIgnored() {
        let held = [HeldReleaseSender.Held(fingerprint: "a", isUnread: true, readAt: now.addingTimeInterval(-9 * 24 * 3600), triagedAt: now)]
        XCTAssertEqual(HeldReleaseSender.plan(held, readHere: []).unread, ["a"])
    }

    func testFingerprintsRoundTrip() {
        let value = HeldReleaseRecordSchema.value(["a", "b"])
        XCTAssertEqual(HeldReleaseRecordSchema.fingerprints(from: value), ["a", "b"])
        XCTAssertEqual(HeldReleaseRecordSchema.fingerprints(from: nil), [])
        XCTAssertEqual(HeldReleaseRecordSchema.fingerprints(from: ""), [])
    }
}
