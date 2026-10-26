import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// An Important notification from this Mac's own apps, during a Focus with Karui's
/// filter, comes again as Karui's banner; the iPhone's verdict has the last word.
final class MacRepostTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(id: String = "notification-12", arrived secondsAgo: TimeInterval = 20, mac: String? = nil, phone: String? = nil) -> Inbox.Item {
        var item = Inbox.Item(id: id, app: "Slack", fingerprint: "print", title: "Kotoba", subtitle: "general", body: "darai: merge please", deliveredAt: now.addingTimeInterval(-secondsAgo))
        if let mac {
            let json = #"{"category":"\#(mac)","reason":"","confidence":0.9,"engine":"onDeviceModel","isModelFallback":false}"#
            item.macVerdict = try? JSONDecoder().decode(MacVerdict.self, from: Data(json.utf8))
        }
        if let phone {
            item.verdict = VerdictRecord(fingerprint: "print", app: "Slack", category: phone, interest: nil, reason: "", triagedAt: now, isUnread: true)
        }
        return item
    }

    func testImportantDuringTheFocusPosts() {
        XCTAssertEqual(MacRepost.action(for: item(mac: "notifyNow"), isFiltering: true, isPosted: false, now: now), .post, "this Mac's sort first")
        XCTAssertEqual(MacRepost.action(for: item(phone: "notifyNow"), isFiltering: true, isPosted: false, now: now), .post, "the iPhone's verdict first")
        XCTAssertEqual(MacRepost.action(for: item(mac: "summary", phone: "notifyNow"), isFiltering: true, isPosted: false, now: now), .post, "the iPhone says Important after this Mac didn't")
    }

    /// No Focus, or one without Karui's filter, which looks the same; not Important;
    /// read; or arrived long enough ago that it's catching up, not news.
    func testOtherwiseNothing() {
        XCTAssertEqual(MacRepost.action(for: item(mac: "notifyNow"), isFiltering: false, isPosted: false, now: now), .none)
        XCTAssertEqual(MacRepost.action(for: item(mac: "summary"), isFiltering: true, isPosted: false, now: now), .none)
        XCTAssertEqual(MacRepost.action(for: item(mac: "notifyNow", phone: "summary"), isFiltering: true, isPosted: false, now: now), .none, "the iPhone's verdict wins")
        var read = item(mac: "notifyNow")
        read.readAt = now
        XCTAssertEqual(MacRepost.action(for: read, isFiltering: true, isPosted: false, now: now), .none)
        XCTAssertEqual(MacRepost.action(for: item(arrived: MacRepost.window + 1, mac: "notifyNow"), isFiltering: true, isPosted: false, now: now), .none)
        XCTAssertEqual(MacRepost.action(for: item(), isFiltering: true, isPosted: false, now: now), .none, "not sorted yet")
    }

    /// Only this Mac's own notifications: one only the iPhone got has its own banner
    /// (`MacBanners`, while at the Mac).
    func testOnlyThisMacsOwn() {
        XCTAssertEqual(MacRepost.action(for: item(id: "phone-print", phone: "notifyNow"), isFiltering: true, isPosted: false, now: now), .none)
    }

    /// Once posted: never twice, and gone when the iPhone disagrees or it's read,
    /// even after the Focus ends.
    func testAPostedBannerStaysOrGoes() {
        XCTAssertEqual(MacRepost.action(for: item(mac: "notifyNow"), isFiltering: true, isPosted: true, now: now), .none)
        XCTAssertEqual(MacRepost.action(for: item(mac: "notifyNow", phone: "summary"), isFiltering: true, isPosted: true, now: now), .withdraw)
        var read = item(mac: "notifyNow")
        read.readAt = now
        XCTAssertEqual(MacRepost.action(for: read, isFiltering: false, isPosted: true, now: now), .withdraw)
    }
}
