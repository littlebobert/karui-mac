import KaruiSorting
import XCTest
@testable import KaruiMac

final class MacTranslationTests: XCTestCase {
    /// As on the iPhone: kana is Japanese, hangul Korean, and handles don't count.
    func testDetectsTheLanguage() {
        XCTAssertEqual(NotificationLanguageDetector.languageCode(for: "明日の会議は10時からです。よろしくお願いします。"), "ja")
        XCTAssertEqual(NotificationLanguageDetector.languageCode(for: "내일 회의는 10시에 시작합니다."), "ko")
        XCTAssertEqual(NotificationLanguageDetector.languageCode(for: "Kannst du mir bitte die Unterlagen bis morgen schicken?"), "de")
        XCTAssertNil(NotificationLanguageDetector.languageCode(for: "ok"))
        XCTAssertNil(NotificationLanguageDetector.languageCode(for: "@darai #internal-kotoba-app-tech"))
    }

    /// Only while the iPhone's setting is on, and never a language the person reads
    /// or the one translations go into.
    func testTranslatesOnlyWhatThePersonDoesntRead() {
        var policy = TriagePolicy.standard
        policy.readLanguages = ["en"]
        policy.translateNotifications = false
        XCTAssertFalse(MacTranslator.shouldTranslate("ja", policy: policy, target: "en"))
        policy.translateNotifications = true
        XCTAssertTrue(MacTranslator.shouldTranslate("ja", policy: policy, target: "en"))
        XCTAssertFalse(MacTranslator.shouldTranslate("en", policy: policy, target: "en"))
        XCTAssertFalse(MacTranslator.shouldTranslate(nil, policy: policy, target: "en"))
        policy.readLanguages = ["en", "ja"]
        XCTAssertFalse(MacTranslator.shouldTranslate("ja", policy: policy, target: "en"))
    }

    /// A sender's name in the title stays; the body follows the notification's language.
    func testLeavesNamesAlone() {
        let fields = TranslatableFields(title: "Yuki Tanaka", subtitle: nil, body: "明日の会議は10時からです。よろしくお願いします。", sender: "Yuki Tanaka")
        XCTAssertEqual(fields.languageCode, "ja")
        XCTAssertEqual(MacTranslator.fieldsNeedingTranslation(fields, from: "ja").map(\.identifier), ["body"])
    }

    /// The translation is what's shown and searched; the original stays on the item.
    func testShowsAndSearchesTheTranslation() {
        var item = Inbox.Item(id: "notification-1", app: "Slack", fingerprint: "f", title: "Yuki", subtitle: "#general", body: "明日の会議は10時からです。", deliveredAt: Date())
        item.translation = NotificationTranslation(sourceLanguage: "ja", targetLanguage: "en", subtitle: "#general", body: "Tomorrow's meeting starts at 10.", translatedAt: Date(), quality: .fast)
        XCTAssertEqual(item.shownTitle, "Yuki")
        XCTAssertEqual(item.shownBody, "Tomorrow's meeting starts at 10.")
        XCTAssertEqual(item.body, "明日の会議は10時からです。")
        XCTAssertEqual(item.compactLine, "#general · Tomorrow's meeting starts at 10.")
        XCTAssertTrue(item.matches("meeting"))
        XCTAssertTrue(item.matches("会議"))
    }
}
