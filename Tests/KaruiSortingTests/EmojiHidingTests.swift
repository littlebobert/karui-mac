import XCTest
@testable import KaruiSorting

final class EmojiHidingTests: XCTestCase {
    func testStripsEmojiOfEveryKindAndKeepsTheRest() {
        XCTAssertEqual(EmojiHiding.strip("Party 🎉 at 7!"), "Party at 7!")
        XCTAssertEqual(EmojiHiding.strip("👨‍👩‍👧‍👦 family dinner 🇯🇵"), "family dinner")
        XCTAssertEqual(EmojiHiding.strip("Thumbs 👍🏽 up ☀️ 1️⃣ done"), "Thumbs up done")
        XCTAssertEqual(EmojiHiding.strip("Order #12 shipped ©2026 — 100%"), "Order #12 shipped ©2026 — 100%")
        XCTAssertEqual(EmojiHiding.strip("明日の歯医者 🦷 予約"), "明日の歯医者 予約")
        XCTAssertEqual(EmojiHiding.strip("Line one 🎉\n🎉 Line two"), "Line one\nLine two")
        XCTAssertEqual(EmojiHiding.strip("🎉🎉🎉"), "")
    }

    func testModesApplyByCategory() {
        XCTAssertFalse(EmojiHiding.hides(.silence, mode: .off))
        XCTAssertTrue(EmojiHiding.hides(.summary, mode: .quiet))
        XCTAssertFalse(EmojiHiding.hides(.notifyNow, mode: .quiet))
        XCTAssertTrue(EmojiHiding.hides(.notifyNow, mode: .all))
    }

    func testShownKeepsTextThatWouldBeLeftEmpty() {
        XCTAssertEqual(EmojiHiding.shown("Sale 🔥", category: .silence, mode: .quiet), "Sale")
        XCTAssertEqual(EmojiHiding.shown("Sale 🔥", category: .notifyNow, mode: .quiet), "Sale 🔥")
        XCTAssertEqual(EmojiHiding.shown("🔥🔥", category: .silence, mode: .all), "🔥🔥")
    }
}
