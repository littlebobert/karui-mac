import KaruiLinkKit
import XCTest
@testable import KaruiMac

@MainActor
final class SlackThreadReplyTests: XCTestCase {
    private let now = Date()
    private let text = "@Justin Garcia About CA authority incident, uv has original root CA lists. Do you think we should update ours?"

    private func inbox() -> Inbox {
        let suite = "SlackThreadReplyTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    /// The Mac's notification of a thread reply: titled by the workspace.
    private func macRecord(id: Int64 = 269, text: String) -> NotificationRecord {
        NotificationRecord(
            id: id, bundleIdentifier: "com.tinyspeck.slackmacgap", deliveredAt: now,
            title: "Kotoba", subtitle: "internal-kotoba-app-tech", body: "darai: \(String(text.prefix(90)))",
            identifier: nil, userInfo: [:]
        )
    }

    /// The iPhone's verdict on the same reply: titled by the sender, the channel
    /// first in the text.
    private func phoneVerdict(text: String) -> VerdictRecord {
        VerdictRecord(
            fingerprint: "phone-print", app: "Slack", category: "notifyNow", interest: 3, reason: "",
            triagedAt: now.addingTimeInterval(6), isUnread: true, title: "darai",
            body: "In #internal-kotoba-app-tech\n\(text)", subtitle: "In #internal-kotoba-app-tech", sender: "darai"
        )
    }

    func testTheSameReplyMatchesEitherWayRound() {
        let phone = LooseMatch.Fields(title: "darai", subtitle: "In #internal-kotoba-app-tech", body: "In #internal-kotoba-app-tech\n\(text)")
        let mac = LooseMatch.Fields(title: "Kotoba", subtitle: "internal-kotoba-app-tech", body: "darai: \(String(text.prefix(90)))")
        XCTAssertTrue(LooseMatch.slackPost(phone, mac))
        XCTAssertFalse(LooseMatch.slackPost(mac, phone), "only the iPhone's says In #")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", mac, phone))
        XCTAssertFalse(LooseMatch.sameNotification(app: "LINE", mac, phone), "Slack's shape only")
        var otherChannel = mac
        otherChannel.subtitle = "internal-kotoba-app-sales"
        XCTAssertFalse(LooseMatch.slackPost(phone, otherChannel), "another channel")
        var otherText = mac
        otherText.body = "darai: something else"
        XCTAssertFalse(LooseMatch.slackPost(phone, otherText), "other text")
    }

    /// The verdict after the Mac's notification joins it, so the row has the link.
    func testAVerdictJoinsTheMacsNotification() {
        let inbox = inbox()
        inbox.add(macRecord(text: text), as: .slack)
        XCTAssertEqual(inbox.apply([phoneVerdict(text: text)]), [])
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertEqual(inbox.items.first?.id, "notification-269")
        XCTAssertEqual(inbox.items.first?.fingerprint, "phone-print")
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }

    /// The Mac's notification after the verdict takes the verdict's row over.
    func testTheMacsNotificationJoinsAnEarlierVerdict() {
        let inbox = inbox()
        inbox.apply([phoneVerdict(text: text)])
        inbox.add(macRecord(text: text), as: .slack)
        XCTAssertEqual(inbox.items.map(\.id), ["notification-269"])
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }

    /// Copies an earlier version kept apart merge into the Mac's own on the next
    /// pass, keeping a read mark made on the copy.
    func testAKeptApartCopyMergesIntoTheMacsOwn() {
        let inbox = inbox()
        var stale = phoneVerdict(text: text)
        stale.subtitle = nil
        inbox.apply([stale])
        inbox.add(macRecord(text: text), as: .slack)
        // The old matching saw no subtitle and kept two rows.
        XCTAssertEqual(inbox.items.count, 2)
        inbox.markRead(ids: ["phone-print"])

        inbox.apply([phoneVerdict(text: text)])
        XCTAssertEqual(inbox.items.map(\.id), ["notification-269"])
        XCTAssertEqual(inbox.items.first?.fingerprint, "phone-print")
        XCTAssertNotNil(inbox.items.first?.readAt)
    }
}
