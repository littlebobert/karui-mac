import XCTest
@testable import KaruiMac

/// A banner's notification opens here, not in its app: selected with the preview,
/// open in full without it, whatever the filters, search, or grouping.
@MainActor
final class RevealTests: XCTestCase {
    private let now = Date()

    private func inbox() -> Inbox {
        let suite = "RevealTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let inbox = Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
        var slack = Inbox.Item(id: "notification-1", app: "Slack", fingerprint: "a", title: "Kotoba", subtitle: "general", body: "darai: merge please", deliveredAt: now)
        slack.readAt = now
        let line = Inbox.Item(id: "phone-b", app: "LINE", fingerprint: "b", title: "Che", subtitle: nil, body: "Home now", deliveredAt: now.addingTimeInterval(-60))
        inbox.replaceItems([slack, line])
        return inbox
    }

    func testWithThePreviewItsSelected() {
        let inbox = inbox()
        inbox.showsPreview = true
        inbox.reveal("phone-b")
        XCTAssertEqual(inbox.selection, ["phone-b"])
        XCTAssertNil(inbox.openItemID)
    }

    func testWithoutThePreviewItOpensInFull() {
        let inbox = inbox()
        inbox.showsPreview = false
        inbox.reveal("phone-b")
        XCTAssertEqual(inbox.openItemID, "phone-b")
    }

    /// Hidden by the Unread filter (it's read) and by a search: shown anyway, until
    /// the selection moves on.
    func testFiltersAndSearchGiveWay() {
        let inbox = inbox()
        inbox.showsPreview = true
        inbox.shownReadStates = [.unread]
        inbox.search = "Home"
        XCTAssertEqual(inbox.sortedVisibleItems.map(\.id), ["phone-b"])
        inbox.reveal("notification-1")
        XCTAssertEqual(inbox.search, "", "a search that leaves it out goes")
        XCTAssertTrue(inbox.sortedVisibleItems.map(\.id).contains("notification-1"))
        inbox.selection = ["phone-b"]
        inbox.keepVisible(inbox.selection)
        XCTAssertFalse(inbox.sortedVisibleItems.map(\.id).contains("notification-1"), "hidden again once the selection moves on")
    }

    func testAGroupingOpensItsGroup() {
        let inbox = inbox()
        inbox.showsPreview = true
        inbox.grouping = .apps
        inbox.reveal("phone-b")
        XCTAssertEqual(inbox.openGroupID, "LINE")
        XCTAssertEqual(inbox.sortedVisibleItems.map(\.id), ["phone-b"])
    }
}
