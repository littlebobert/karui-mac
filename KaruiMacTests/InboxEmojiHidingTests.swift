import XCTest
@testable import KaruiMac
import KaruiSorting

/// The iPhone's Hide Emoji, as the Mac's inbox lists follow it.
final class InboxEmojiHidingTests: XCTestCase {
    private func item(_ category: String?, title: String = "Sam 🎉") -> Inbox.Item {
        var item = Inbox.Item(id: UUID().uuidString, app: "Messages", fingerprint: "f", title: title,
                              subtitle: nil, body: "Party 🎉 at 7", deliveredAt: .now)
        item.chosenCategory = category
        return item
    }

    func testOnlyNeutralAndSpamKeepsImportantAsItCame() {
        XCTAssertEqual(item("silence").listed("Party 🎉 at 7", hidingEmoji: .quiet), "Party at 7")
        XCTAssertEqual(item("summary").listed("Party 🎉 at 7", hidingEmoji: .quiet), "Party at 7")
        XCTAssertEqual(item("notifyNow").listed("Party 🎉 at 7", hidingEmoji: .quiet), "Party 🎉 at 7")
        XCTAssertEqual(item(nil).listed("Party 🎉 at 7", hidingEmoji: .quiet), "Party 🎉 at 7", "not sorted yet")
    }

    func testEverythingAndOff() {
        XCTAssertEqual(item(nil).listed("Party 🎉 at 7", hidingEmoji: .all), "Party at 7")
        XCTAssertEqual(item("silence").listed("Party 🎉 at 7", hidingEmoji: .off), "Party 🎉 at 7")
        XCTAssertNil(item("silence").listed(nil, hidingEmoji: .all))
    }

    func testAGroupWithAnythingImportantKeepsItsName() {
        let quiet = Inbox.Group(id: "g", title: "Sam 🎉", app: "Messages", items: [item("silence"), item("summary")])
        let mixed = Inbox.Group(id: "g", title: "Sam 🎉", app: "Messages", items: [item("silence"), item("notifyNow")])
        XCTAssertEqual(quiet.shownTitle(hidingEmoji: .quiet), "Sam")
        XCTAssertEqual(mixed.shownTitle(hidingEmoji: .quiet), "Sam 🎉")
        XCTAssertEqual(mixed.shownTitle(hidingEmoji: .all), "Sam")
    }
}
