import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// An email read here before the iPhone's copy of it arrived: the Mac's row takes the
/// iPhone's fingerprint in a loose match, and the iPhone, which knows it only by that
/// fingerprint, has to be told it was read or it keeps its alert.
@MainActor
final class LooseMatchReadTests: XCTestCase {
    private let now = Date()
    private let text = "@Justin Garcia About CA authority incident, uv has original root CA lists. Do you think we should update ours?"

    private func inbox() -> Inbox {
        let suite = "LooseMatchReadTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    private func macRecord() -> NotificationRecord {
        NotificationRecord(
            id: 269, bundleIdentifier: "com.tinyspeck.slackmacgap", deliveredAt: now,
            title: "Kotoba", subtitle: "internal-kotoba-app-tech", body: "darai: \(String(text.prefix(90)))",
            identifier: nil, userInfo: [:]
        )
    }

    private func phoneVerdict(isUnread: Bool = true) -> VerdictRecord {
        VerdictRecord(
            fingerprint: "phone-print", app: "Slack", category: "notifyNow", interest: 3, reason: "",
            triagedAt: now.addingTimeInterval(240), isUnread: isUnread, title: "darai",
            body: "In #internal-kotoba-app-tech\n\(text)", subtitle: "In #internal-kotoba-app-tech", sender: "darai"
        )
    }

    /// The Mac's notification, linked, then the iPhone's verdict on it.
    private func matched(readHereFirst: Bool, verdict: VerdictRecord? = nil) -> (Inbox, String) {
        let inbox = inbox()
        let record = macRecord()
        inbox.add(record, as: .slack)
        let macPrint = Inbox.fingerprint(for: record, as: .slack)
        inbox.setLink(
            DeepLinkRecord(fingerprint: macPrint, app: "Slack", url: URL(string: "slack://channel?team=T0123ABCDEF&id=C0ABCDEFGHI")!, opensExactContent: true, deliveredAt: now),
            for: record
        )
        if readHereFirst { inbox.markRead(fingerprint: macPrint) }
        inbox.apply([verdict ?? phoneVerdict()])
        XCTAssertEqual(inbox.items.first?.fingerprint, "phone-print", "the loose match")
        return (inbox, macPrint)
    }

    func testReadHereFirstGoesReadUnderTheIPhonesFingerprint() {
        let (inbox, macPrint) = matched(readHereFirst: true)
        let relinks = inbox.relinks()
        XCTAssertEqual(relinks.map(\.link.fingerprint), ["phone-print"])
        XCTAssertEqual(relinks.first?.previousFingerprint, macPrint)
        XCTAssertEqual(relinks.first?.readHere, true)

        relinks.forEach { inbox.setLink($0.link) }
        XCTAssertEqual(inbox.relinks(), [], "sent again once")
    }

    func testUnreadHereStaysUnread() {
        let (inbox, _) = matched(readHereFirst: false)
        XCTAssertEqual(inbox.relinks().map(\.readHere), [false])
    }

    /// Read on the iPhone already: it has no alert left to clear.
    func testReadOnTheIPhoneIsntSentAgain() {
        let (inbox, _) = matched(readHereFirst: true, verdict: phoneVerdict(isUnread: false))
        XCTAssertEqual(inbox.relinks().map(\.readHere), [false])
    }

    /// Read here after the match: the watcher reports it under the iPhone's
    /// fingerprint, which the inbox and the iPhone know it by.
    func testALaterReadIsReportedUnderTheIPhonesFingerprint() async {
        let watcher = ReadWatcher()
        let link = DeepLinkRecord(fingerprint: "mac-print", app: "Slack", url: URL(string: "slack://open")!, opensExactContent: true, deliveredAt: now)
        await watcher.track(HarvestedLink(link: link, readProbe: nil, notificationID: 269))
        await watcher.rename("mac-print", to: "phone-print")
        await watcher.rename("unknown", to: "other")
        let read = await watcher.notificationDisappeared(id: 269)
        XCTAssertEqual(read.map(\.link.fingerprint), ["phone-print"])
        let count = await watcher.count
        XCTAssertEqual(count, 0)
    }
}
