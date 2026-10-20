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

    /// With only unread ones shown, one read by selecting it stays until the
    /// selection moves on, as in Mail.
    func testAReadSelectionStaysUnderTheUnreadFilterUntilItMoves() {
        let suite = "InboxVerdictTests.\(UUID().uuidString)"
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        inbox.apply([verdict("a"), verdict("b")])
        inbox.shownReadStates = [.unread]
        inbox.selection = ["a"]
        inbox.keepVisible(inbox.selection)
        inbox.markRead(ids: ["a"])
        XCTAssertEqual(Set(inbox.filtered.map(\.id)), ["a", "b"])
        inbox.selection = ["b"]
        inbox.keepVisible(inbox.selection)
        XCTAssertEqual(inbox.filtered.map(\.id), ["b"])
    }
}
