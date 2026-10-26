import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A verdict record is named by the fingerprint, so "sent a photo." from one person
/// is one record, and a read mark left on last week's came with today's: the Mac took
/// it as read and showed no banner.
final class StaleReadMarkTests: XCTestCase {
    private let triagedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testAReadMarkFromAnEarlierNotificationIsIgnored() {
        let lastWeek = triagedAt.addingTimeInterval(-9 * 24 * 60 * 60)
        XCTAssertNil(VerdictStore.current(lastWeek, triagedAt: triagedAt))
        XCTAssertNil(VerdictStore.current(nil, triagedAt: triagedAt))
    }

    /// Read after it was sorted, or read here before the iPhone answered the Mac's
    /// request to sort it.
    func testThisNotificationsReadMarkStands() {
        let after = triagedAt.addingTimeInterval(90)
        XCTAssertEqual(VerdictStore.current(after, triagedAt: triagedAt), after)
        let beforeTheAnswer = triagedAt.addingTimeInterval(-60 * 60)
        XCTAssertEqual(VerdictStore.current(beforeTheAnswer, triagedAt: triagedAt), beforeTheAnswer)
    }

    /// A verdict the push missed, found by the next full pass and the poll after it,
    /// still gets its banner.
    @MainActor
    func testBannersCoverTheFullPass() {
        let seconds = { (duration: Duration) in Double(duration.components.seconds) }
        let freshness = MacBanners.freshness
        XCTAssertGreaterThan(freshness, seconds(VerdictStore.fullPassInterval) + seconds(VerdictStore.pollInterval))
    }
}
