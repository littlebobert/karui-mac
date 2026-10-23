import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A Slack direct message is titled by the workspace on the Mac, with the sender as
/// its subtitle, and by the sender on the iPhone, with no subtitle: one row, not two.
@MainActor
final class SlackDirectMessageTests: XCTestCase {
    private let now = Date()

    private func inbox() -> Inbox {
        let suite = "SlackDirectMessageTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    private func macRecord() -> NotificationRecord {
        NotificationRecord(
            id: 360, bundleIdentifier: "com.tinyspeck.slackmacgap", deliveredAt: now,
            title: "Kotoba", subtitle: "Sam Reyes", body: "Sorry I gotta head out for lunch",
            identifier: nil, userInfo: [:]
        )
    }

    private func phoneVerdict() -> VerdictRecord {
        VerdictRecord(
            fingerprint: "phone-print", app: "Slack", category: "notifyNow", interest: 3, reason: "",
            triagedAt: now.addingTimeInterval(9), isUnread: true, title: "Sam Reyes",
            body: "Sorry I gotta head out for lunch", subtitle: nil, sender: "Sam Reyes"
        )
    }

    func testAVerdictJoinsTheMacsNotification() {
        let inbox = inbox()
        inbox.add(macRecord(), as: .slack)
        XCTAssertEqual(inbox.apply([phoneVerdict()]), [])
        XCTAssertEqual(inbox.items.map(\.id), ["notification-360"])
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }

    func testTheMacsNotificationJoinsAnEarlierVerdict() {
        let inbox = inbox()
        inbox.apply([phoneVerdict()])
        inbox.add(macRecord(), as: .slack)
        XCTAssertEqual(inbox.items.map(\.id), ["notification-360"])
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }
}
