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

    /// A saved link survives a relaunch when it's the kind its app's harvester makes,
    /// Slack's web permalinks included; one from another app is dropped.
    func testSavedLinksKeptOnlyForTheirOwnApp() {
        XCTAssertTrue(Inbox.linkFits(URL(string: "https://example.slack.com/archives/C0ABCDEFGHI/p1791879249798639")!, app: "Slack"))
        XCTAssertTrue(Inbox.linkFits(URL(string: "slack://channel?team=T0123ABCDEF&id=C0ABCDEFGHI")!, app: "Slack"))
        XCTAssertTrue(Inbox.linkFits(URL(string: "readdle-spark://bl=QTo")!, app: "Spark"))
        XCTAssertFalse(Inbox.linkFits(URL(string: "readdle-spark://bl=QTo")!, app: "Slack"))
        XCTAssertFalse(Inbox.linkFits(URL(string: "https://example.slack.com/archives/C0ABCDEFGHI/p1791879249798639")!, app: "Messages"))
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

    /// A device that comes back online with an older History can't make what was read
    /// on another unread again.
    func testAReadVerdictStaysReadWhenAnotherDeviceSaysUnread() {
        let suite = "InboxVerdictTests.\(UUID().uuidString)"
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        inbox.apply([verdict("a")])
        var read = verdict("a")
        read.isUnread = false
        inbox.apply([read])
        XCTAssertEqual(inbox.item(id: "a")?.isUnread, false)

        var iPadsOlder = verdict("a")
        iPadsOlder.reason = "From the iPad"
        inbox.apply([iPadsOlder])
        XCTAssertEqual(inbox.item(id: "a")?.isUnread, false)
        XCTAssertEqual(inbox.item(id: "a")?.verdict?.reason, "From the iPad", "the rest of the verdict still comes through")
    }

    /// Turning on the Unread filter hides a selection already read and drops it from
    /// the selection, so the preview clears; what's left selected isn't read by it.
    func testTheUnreadFilterHidesASelectionAlreadyRead() {
        let suite = "InboxVerdictTests.\(UUID().uuidString)"
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        inbox.apply([verdict("a"), verdict("b"), verdict("c")])
        inbox.selection = ["a"]
        inbox.keepVisible(inbox.selection)
        inbox.markRead(ids: ["a"])
        XCTAssertFalse(inbox.takeSelectionTrim(), "the person selected that")

        inbox.selection = ["a", "b"]
        inbox.shownReadStates = [.unread]
        XCTAssertEqual(Set(inbox.filtered.map(\.id)), ["b", "c"])
        XCTAssertEqual(inbox.selection, ["b"])
        XCTAssertTrue(inbox.takeSelectionTrim(), "the filter's trim, so b isn't read by it")
        XCTAssertFalse(inbox.takeSelectionTrim())
    }
}
