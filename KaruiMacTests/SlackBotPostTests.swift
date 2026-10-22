import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A bot posts the same message every build, different only past the part of the
/// text the fingerprint keeps: "📦 iOS build uploaded to TestFlight by … Tag:
/// release/ios/2.0.0-206" one day, "…-207" the next.
@MainActor
final class SlackBotPostTests: XCTestCase {
    private let now = Date()
    private let yesterday = Date().addingTimeInterval(-32 * 60 * 60)

    private func inbox() -> Inbox {
        let suite = "SlackBotPostTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    private func text(build: Int) -> String {
        "📦 iOS build uploaded to TestFlight by mika\nTag: release/ios/2.0.0-\(build) • Env: .env.production"
    }

    /// The Mac's notification: titled by the workspace, the channel as its subtitle,
    /// no sender before a bot's text.
    private func macRecord(id: Int64, build: Int, at date: Date) -> NotificationRecord {
        NotificationRecord(
            id: id, bundleIdentifier: "com.tinyspeck.slackmacgap", deliveredAt: date,
            title: "Kotoba", subtitle: "app-tech", body: text(build: build),
            identifier: nil, userInfo: [:]
        )
    }

    /// The iPhone's verdict: titled by the bot, "To channel" as its subtitle and its
    /// text's first line.
    private func phoneVerdict(build: Int, at date: Date) -> VerdictRecord {
        VerdictRecord(
            fingerprint: "phone-print-\(build)", app: "Slack", category: "summary", interest: 2, reason: "",
            triagedAt: date.addingTimeInterval(25), isUnread: true, title: "Build Bot (bot)",
            body: "To app-tech\n\(text(build: build))", subtitle: "To app-tech", sender: "Build Bot"
        )
    }

    func testTheTwoBuildsShareAFingerprint() {
        XCTAssertEqual(
            Inbox.fingerprint(for: macRecord(id: 1, build: 206, at: now), as: .slack),
            Inbox.fingerprint(for: macRecord(id: 2, build: 207, at: now), as: .slack)
        )
    }

    /// The iPhone's answer to the Mac's request to sort yesterday's post, filed under
    /// the Mac's own fingerprint.
    private func sortRequestAnswer(build: Int, at date: Date) -> VerdictRecord {
        VerdictRecord(
            fingerprint: Inbox.fingerprint(for: macRecord(id: 1, build: build, at: date), as: .slack),
            app: "Slack", category: "summary", interest: 2, reason: "", triagedAt: date.addingTimeInterval(120),
            isUnread: false, title: "Kotoba", body: "app-tech\n\(text(build: build))", subtitle: "app-tech"
        )
    }

    /// Today's post doesn't take over yesterday's row and its verdict, and today's
    /// verdict joins today's post: one row each, no copy only the iPhone seems to have.
    func testTodaysPostAndVerdictStayApartFromYesterdays() {
        let inbox = inbox()
        inbox.add(macRecord(id: 250, build: 206, at: yesterday), as: .slack)
        inbox.apply([sortRequestAnswer(build: 206, at: yesterday)])
        XCTAssertEqual(inbox.items.map(\.id), ["notification-250"])
        XCTAssertNotNil(inbox.items.first?.verdict)

        inbox.add(macRecord(id: 304, build: 207, at: now), as: .slack)
        XCTAssertEqual(Set(inbox.items.map(\.id)), ["notification-250", "notification-304"])
        let today = inbox.items.first { $0.id == "notification-304" }
        XCTAssertNil(today?.verdict, "yesterday's verdict stays with yesterday's post")

        XCTAssertEqual(inbox.apply([sortRequestAnswer(build: 206, at: yesterday), phoneVerdict(build: 207, at: now)]), [])
        XCTAssertEqual(Set(inbox.items.map(\.id)), ["notification-250", "notification-304"])
        XCTAssertEqual(inbox.items.first { $0.id == "notification-304" }?.fingerprint, "phone-print-207")
        XCTAssertEqual(inbox.items.first { $0.id == "notification-250" }?.deliveredAt, yesterday)
    }

    /// Notification Center gives today's post yesterday's ID: a new notification, not
    /// the same one seen again, so yesterday's is kept under another ID.
    func testAReusedIDWithTheSameFingerprintIsANewNotification() {
        let inbox = inbox()
        inbox.add(macRecord(id: 304, build: 206, at: yesterday), as: .slack)
        XCTAssertTrue(inbox.add(macRecord(id: 304, build: 207, at: now), as: .slack))
        XCTAssertEqual(inbox.items.count, 2)
        XCTAssertEqual(inbox.items.first { $0.id == "notification-304" }?.deliveredAt, now)
        // The same notification read again, as when the harvest catches up, is not.
        XCTAssertFalse(inbox.add(macRecord(id: 304, build: 207, at: now), as: .slack))
    }
}
