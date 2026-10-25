import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A Spark email the iPhone and the Mac each cut differently: Spark for Mac repeats
/// the email's first line, so the text never matched, and only the link made from
/// the iPhone's verdict showed it was the same email.
@MainActor
final class SameLinkMergeTests: XCTestCase {
    private let now = Date()
    private let subject = "Please confirm your newsletter sign up, thanks!"
    private let emailURL = URL(string: "readdle-spark://bl=QTphZGFAZXhhbXBsZS5jb207SUQ6MjAyNjEwMjUuMUBtYWlsLmV4YW1wbGUuY29t")!

    private func inbox() -> Inbox {
        let suite = "SameLinkMergeTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    private func macRecord() -> NotificationRecord {
        NotificationRecord(
            id: 444, bundleIdentifier: "com.readdle.sparkdesktop", deliveredAt: now,
            title: "Nesting House", subtitle: subject,
            body: "Get the latest Nesting House news... Get the latest Nesting House news... We send about two newsletters a month",
            identifier: nil, userInfo: [:]
        )
    }

    private func phoneVerdict() -> VerdictRecord {
        VerdictRecord(
            fingerprint: "phone-print", app: "Spark", category: "summary", interest: 1, reason: "",
            triagedAt: now.addingTimeInterval(2), isUnread: true, title: "Nesting House",
            body: "\(subject)\nGet the latest Nesting House news... We send about two newsletters a month with seasonal releases",
            subtitle: subject, sender: "Nesting House"
        )
    }

    private func link(_ fingerprint: String, url: URL? = nil, app: String = "Spark", exact: Bool = true) -> DeepLinkRecord {
        DeepLinkRecord(fingerprint: fingerprint, app: app, url: url ?? emailURL, opensExactContent: exact, deliveredAt: now)
    }

    func testTheTextAloneDoesntMatch() {
        let mac = macRecord(), phone = phoneVerdict()
        XCTAssertFalse(Inbox.looselyMatches(
            Inbox.Item(id: "notification-444", app: "Spark", fingerprint: "mac-print", title: mac.title, subtitle: mac.subtitle, body: mac.body, deliveredAt: now),
            app: "Spark", title: phone.title, subtitle: phone.subtitle, body: phone.body, at: phone.triagedAt
        ))
    }

    /// The Mac's notification, then the iPhone's verdict kept apart, then the link
    /// for each: one row, the Mac's, with the iPhone's verdict.
    func testTheSameEmailLinkMergesTheStandInIntoTheMacsCopy() {
        let inbox = inbox()
        let record = macRecord()
        inbox.add(record, as: .spark)
        inbox.apply([phoneVerdict()])
        XCTAssertEqual(inbox.items.count, 2)
        inbox.setLink(link(Inbox.fingerprint(for: record, as: .spark)), for: record)
        XCTAssertEqual(inbox.items.count, 2, "the stand-in has no link yet")
        inbox.selection = ["phone-print"]
        inbox.setLink(link("phone-print"))
        XCTAssertEqual(inbox.items.map(\.id), ["notification-444"])
        let item = inbox.items[0]
        XCTAssertEqual(item.fingerprint, "phone-print")
        XCTAssertEqual(item.verdict?.category, "summary")
        XCTAssertEqual(item.link?.fingerprint, "phone-print")
        XCTAssertEqual(item.body, record.body, "the Mac's own text")
        XCTAssertEqual(inbox.selection, ["notification-444"])
    }

    /// Pairs already stored apart merge as the inbox loads, keeping a read mark made
    /// on either.
    func testAStoredPairMerges() {
        let inbox = inbox()
        var copy = Inbox.Item(id: "notification-444", app: "Spark", fingerprint: "mac-print", title: "Nesting House", subtitle: subject, body: "Get the latest", deliveredAt: now)
        copy.link = link("mac-print")
        var standIn = Inbox.Item(id: "phone-print", app: "Spark", fingerprint: "phone-print", title: "Nesting House", subtitle: subject, body: subject, deliveredAt: now.addingTimeInterval(2))
        standIn.link = link("phone-print")
        standIn.verdict = phoneVerdict()
        standIn.readAt = now.addingTimeInterval(10)
        inbox.replaceItems([standIn, copy])
        inbox.mergeSameLink()
        XCTAssertEqual(inbox.items.map(\.id), ["notification-444"])
        XCTAssertEqual(inbox.items.first?.readAt, standIn.readAt)
        XCTAssertEqual(inbox.items.first?.verdict?.category, "summary")
    }

    /// The same link far apart in time, or another email's, stays apart.
    func testOtherTimesAndOtherLinksStayApart() {
        let inbox = inbox()
        var copy = Inbox.Item(id: "notification-444", app: "Spark", fingerprint: "mac-print", title: "Nesting House", subtitle: subject, body: "Get the latest", deliveredAt: now)
        copy.link = link("mac-print")
        var later = Inbox.Item(id: "phone-print", app: "Spark", fingerprint: "phone-print", title: "Nesting House", subtitle: subject, body: subject, deliveredAt: now.addingTimeInterval(LooseMatch.window + 60))
        later.link = link("phone-print")
        later.verdict = phoneVerdict()
        var other = Inbox.Item(id: "other-print", app: "Spark", fingerprint: "other-print", title: "Nesting House", subtitle: subject, body: subject, deliveredAt: now)
        other.link = link("other-print", url: URL(string: "readdle-spark://bl=other")!)
        other.verdict = phoneVerdict()
        inbox.replaceItems([later, copy, other])
        inbox.mergeSameLink()
        XCTAssertEqual(inbox.items.count, 3)
    }

    /// A Messages link opens the conversation, so two messages from one person share
    /// it: they stay two rows.
    func testConversationLinksStayApart() {
        let inbox = inbox()
        let chat = URL(string: "sms:+15555550100")!
        var copy = Inbox.Item(id: "notification-12", app: "Messages", fingerprint: "mac-print", title: "Mom", subtitle: nil, body: "Dinner?", deliveredAt: now)
        copy.link = link("mac-print", url: chat, app: "Messages")
        var standIn = Inbox.Item(id: "phone-print", app: "Messages", fingerprint: "phone-print", title: "Mom", subtitle: nil, body: "Call me", deliveredAt: now)
        standIn.link = link("phone-print", url: chat, app: "Messages")
        standIn.verdict = phoneVerdict()
        inbox.replaceItems([standIn, copy])
        inbox.mergeSameLink()
        XCTAssertEqual(inbox.items.count, 2)
    }
}
