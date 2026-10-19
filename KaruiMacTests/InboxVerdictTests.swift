import KaruiLinkKit
import XCTest
@testable import KaruiMac

@MainActor
final class InboxVerdictTests: XCTestCase {
    private func verdict(_ fingerprint: String, title: String? = "Mom", body: String? = "Call me") -> VerdictRecord {
        VerdictRecord(
            fingerprint: fingerprint, app: "LINE", category: "notifyNow", interest: 3,
            reason: "", triagedAt: Date(), isUnread: true, title: title, body: body
        )
    }

    /// The Mac's banners go only to notifications only the iPhone received that are
    /// new here, once each.
    func testApplyReturnsNewPhoneOnlyItemsOnce() {
        let suite = "InboxVerdictTests.\(UUID().uuidString)"
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(inbox.apply([verdict("a"), verdict("b", title: nil, body: nil)]), ["a"])
        XCTAssertEqual(inbox.apply([verdict("a")]), [])
    }
}
