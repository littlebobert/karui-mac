import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// The Mac gets an email first and asks the iPhone to sort it; the iPhone answers
/// under the Mac's fingerprint, then gets the email itself and sorts it again under
/// its own. Its own verdict takes over the Mac's row instead of standing beside it
/// (a Vercel email, 2026-11-09).
@MainActor
final class SortAnswerTakeoverTests: XCTestCase {
    private let now = Date()
    private let subject = "Blocked deployment to web.dotsu"
    private let text = "Deployment blocked Hello, justingarcia-4063. Your commit to web.dotsu on the Kotoba Technologies team was blocked. You need contributing access to deploy."

    private func inbox() -> Inbox {
        let suite = "SortAnswerTakeoverTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil)
    }

    private func macRecord() -> NotificationRecord {
        NotificationRecord(
            id: 1333, bundleIdentifier: "com.readdle.SparkDesktop", deliveredAt: now,
            title: "Vercel", subtitle: subject, body: text, identifier: nil, userInfo: [:]
        )
    }

    /// The iPhone's answer to the Mac's request: under the Mac's fingerprint.
    private func sortAnswer(_ macPrint: String) -> VerdictRecord {
        VerdictRecord(
            fingerprint: macPrint, app: "Spark", category: "summary", interest: 2, reason: "",
            triagedAt: now.addingTimeInterval(-2), isUnread: true,
            title: "Vercel", body: "\(subject)\n\(text)", subtitle: subject, engine: "privateCloudCompute"
        )
    }

    /// The iPhone's own copy, with a space before the full stop.
    private func phoneVerdict(_ fingerprint: String = "phone-print") -> VerdictRecord {
        VerdictRecord(
            fingerprint: fingerprint, app: "Spark", category: "notifyNow", interest: 4, reason: "",
            triagedAt: now.addingTimeInterval(14), isUnread: true,
            title: "Vercel", body: "\(subject)\nDeployment blocked Hello, justingarcia-4063 . Your commit to web.dotsu on the Kotoba Technologies team was blocked.",
            subtitle: subject, engine: "karuiCloud"
        )
    }

    func testTheIPhonesOwnVerdictTakesOverTheMacsRow() {
        let inbox = inbox()
        let record = macRecord()
        inbox.add(record, as: .spark)
        let macPrint = Inbox.fingerprint(for: record, as: .spark)
        inbox.apply([sortAnswer(macPrint)])
        XCTAssertEqual(inbox.items.first?.verdict?.category, "summary")

        inbox.apply([sortAnswer(macPrint), phoneVerdict()])
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertEqual(inbox.items.first?.id, "notification-1333")
        XCTAssertEqual(inbox.items.first?.fingerprint, "phone-print")
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")

        // Every fetch brings both again: still one row, still the iPhone's verdict.
        inbox.apply([sortAnswer(macPrint), phoneVerdict()])
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }

    /// The iPhone's verdict first, then the Mac's notification: the stand-in becomes
    /// the Mac's row, though one has a space before the full stop.
    func testAStandInBecomesTheMacsNotificationWhateverItsSpacing() {
        let inbox = inbox()
        inbox.apply([phoneVerdict()])
        XCTAssertEqual(inbox.items.map(\.id), ["phone-print"])

        inbox.add(macRecord(), as: .spark)
        XCTAssertEqual(inbox.items.map(\.id), ["notification-1333"])
        XCTAssertEqual(inbox.items.first?.verdict?.category, "notifyNow")
    }

    /// Every row against every verdict, on each fetch: a month of rows, 300 with sort
    /// answers, and a day's verdicts from the iPhone. About a second in a Debug build
    /// (0.10.8 took the same); with the fingerprint made first, 0.10.9 held the main
    /// thread for minutes.
    func testAFullInboxAppliesQuickly() {
        let inbox = inbox()
        var answers: [VerdictRecord] = []
        for index in 0..<3_000 {
            let record = NotificationRecord(
                id: Int64(10_000 + index), bundleIdentifier: "com.readdle.SparkDesktop",
                deliveredAt: now.addingTimeInterval(-Double(index) * 600),
                title: "Sender \(index % 40)", subtitle: "Subject \(index)", body: "Text of email number \(index), long enough to matter.",
                identifier: nil, userInfo: [:]
            )
            inbox.add(record, as: .spark)
            if index < 300 {
                answers.append(VerdictRecord(
                    fingerprint: Inbox.fingerprint(for: record, as: .spark), app: "Spark", category: "summary",
                    interest: 2, reason: "", triagedAt: record.deliveredAt ?? now, isUnread: true
                ))
            }
        }
        let phone = (0..<300).map { index in
            VerdictRecord(
                fingerprint: "phone-\(index)", app: "Spark", category: "notifyNow", interest: 3, reason: "",
                triagedAt: now.addingTimeInterval(-Double(index) * 300), isUnread: true,
                title: "Someone \(index)", body: "Another email \(index)", subtitle: "Other \(index)"
            )
        }
        inbox.apply(answers)
        let start = Date()
        inbox.apply(answers + phone)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// A row already joined to one iPhone notification isn't taken by another.
    func testAJoinedRowIsntTakenAgain() {
        let inbox = inbox()
        inbox.add(macRecord(), as: .spark)
        inbox.apply([phoneVerdict("first-print")])
        XCTAssertEqual(inbox.items.first?.fingerprint, "first-print")

        inbox.apply([phoneVerdict("first-print"), phoneVerdict("second-print")])
        XCTAssertEqual(inbox.items.first(where: { $0.id == "notification-1333" })?.fingerprint, "first-print")
        XCTAssertEqual(inbox.items.count, 2)
    }
}
