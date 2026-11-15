import CloudKit
import KaruiLinkKit
import XCTest
@testable import KaruiMac

/// A calendar alert copied to several days has the same text each day, so one
/// fingerprint, and one record on iCloud for all of them (2026-11-15). On the days
/// the iPhone didn't get it, the Mac took the earlier day's record for its answer and
/// never asked the iPhone; a read on one Mac went onto that record, where another
/// Mac marked the earlier day's and left that day's unread for good; and what a Mac
/// had sorted Neutral itself sat under the Unread filter with no dot, looking read.
@MainActor
final class RepeatedNotificationTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let monday = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeInbox() -> (inbox: Inbox, suite: String) {
        let suite = "RepeatedNotificationTests.\(UUID().uuidString)"
        return (Inbox(defaults: UserDefaults(suiteName: suite)!, store: nil), suite)
    }

    /// This Mac's own copy of the alert, as Notification Center has it.
    private func alert(_ id: Int64, at date: Date, title: String = "study") -> NotificationRecord {
        NotificationRecord(
            id: id, bundleIdentifier: "com.readdle.sparkdesktop", deliveredAt: date,
            title: title, subtitle: nil, body: "Starts in 10 minutes at 9:00", identifier: nil, userInfo: [:]
        )
    }

    private func macVerdict(_ category: String) -> MacVerdict {
        let json = #"{"category":"\#(category)","reason":"","confidence":1,"engine":"Transparent rules","isModelFallback":false}"#
        return try! JSONDecoder().decode(MacVerdict.self, from: Data(json.utf8))
    }

    private func iPhonesVerdict(for record: NotificationRecord, at date: Date) -> VerdictRecord {
        VerdictRecord(
            fingerprint: Inbox.fingerprint(for: record, as: .spark), app: "Spark", category: "notifyNow",
            interest: nil, reason: "", triagedAt: date, isUnread: true, title: record.title, body: record.body
        )
    }

    /// With no verdict from the iPhone, only what this Mac sorted Important is unread,
    /// as the iPhone has it; the Unread filter leaves the rest out.
    func testWhatThisMacSortedNeutralIsReadWithoutTheIPhonesVerdict() {
        let (inbox, suite) = makeInbox()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        inbox.add(alert(1, at: monday), as: .spark)
        inbox.add(alert(2, at: monday.addingTimeInterval(day)), as: .spark)
        inbox.add(alert(3, at: monday.addingTimeInterval(2 * day)), as: .spark)
        XCTAssertEqual(inbox.items.map(\.isUnread), [true, true, true], "not sorted anywhere yet")

        inbox.setMacVerdict(macVerdict("summary"), id: "notification-1")
        inbox.setMacVerdict(macVerdict("notifyNow"), id: "notification-2")
        inbox.setMacVerdict(macVerdict("silence"), id: "notification-3")
        XCTAssertEqual(inbox.item(id: "notification-1")?.isUnread, false)
        XCTAssertEqual(inbox.item(id: "notification-2")?.needsAttention, true)
        XCTAssertEqual(inbox.item(id: "notification-3")?.isUnread, false)
        inbox.shownReadStates = [.unread]
        XCTAssertEqual(inbox.filtered.map(\.id), ["notification-2"])

        // The iPhone's verdict, once there is one, says which it is.
        inbox.apply([iPhonesVerdict(for: alert(1, at: monday), at: monday)])
        XCTAssertEqual(inbox.item(id: "notification-1")?.needsAttention, true)
    }

    /// The iPhone got Monday's alert only, so iCloud's record is Monday's. Tuesday's,
    /// read on another Mac, leaves its mark there: every one of that text from before
    /// the mark is read here, and Wednesday's, which came after it, isn't.
    func testAReadOnAnotherMacReachesEveryEarlierOneOfTheText() {
        let (inbox, suite) = makeInbox()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        for (id, offset) in [(Int64(1), 0.0), (2, day), (3, 2 * day)] {
            inbox.add(alert(id, at: monday.addingTimeInterval(offset)), as: .spark)
            inbox.setMacVerdict(macVerdict("notifyNow"), id: "notification-\(id)")
        }
        inbox.add(alert(4, at: monday.addingTimeInterval(day), title: "another event"), as: .spark)
        inbox.setMacVerdict(macVerdict("notifyNow"), id: "notification-4")
        var mondays = iPhonesVerdict(for: alert(1, at: monday), at: monday)
        inbox.apply([mondays])
        XCTAssertEqual(inbox.items.filter(\.isUnread).count, 4)

        mondays.readAt = monday.addingTimeInterval(day + 17)
        inbox.apply([mondays])
        XCTAssertEqual(inbox.item(id: "notification-1")?.isUnread, false)
        XCTAssertEqual(inbox.item(id: "notification-2")?.isUnread, false, "Tuesday's, which the mark was made for")
        XCTAssertEqual(inbox.item(id: "notification-3")?.isUnread, true, "arrived after the mark")
        XCTAssertEqual(inbox.item(id: "notification-4")?.isUnread, true, "other text")
        XCTAssertEqual(inbox.items.count, 4, "no row of its own for the mark")
    }

    /// As the person leaves, what was read here cancels the alerts the iPhone held.
    /// Yesterday's alert, read then, mustn't cancel today's with the same text, still
    /// unread; nor may one this Mac sorted Neutral that nobody read.
    func testWhatWasReadHereLeavesOutTextStillUnread() {
        let (inbox, suite) = makeInbox()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let now = monday.addingTimeInterval(day + 60)
        // The same text an hour ago and just now; another, read; a third, Neutral here.
        inbox.add(alert(1, at: now.addingTimeInterval(-3600)), as: .spark)
        inbox.add(alert(2, at: now.addingTimeInterval(-30)), as: .spark)
        inbox.add(alert(3, at: now.addingTimeInterval(-600), title: "read here"), as: .spark)
        inbox.add(alert(4, at: now.addingTimeInterval(-600), title: "neutral here"), as: .spark)
        inbox.add(alert(5, at: now.addingTimeInterval(-3 * day), title: "read days ago"), as: .spark)
        for id in [1, 2, 3, 5] { inbox.setMacVerdict(macVerdict("notifyNow"), id: "notification-\(id)") }
        inbox.setMacVerdict(macVerdict("summary"), id: "notification-4")
        inbox.markRead(ids: ["notification-1", "notification-3", "notification-5"], at: now)

        let readHere = Inbox.fingerprint(for: alert(3, at: now, title: "read here"), as: .spark)
        XCTAssertEqual(inbox.fingerprintsReadHere(now: now), [readHere])

        inbox.markRead(ids: ["notification-2"], at: now)
        XCTAssertEqual(inbox.fingerprintsReadHere(now: now), [readHere, Inbox.fingerprint(for: alert(2, at: now), as: .spark)])
    }

    /// iCloud's record for the text is an earlier day's, sorted or only asked about:
    /// not this notification's answer. One from within the verdict's reach is.
    func testAnEarlierDaysRecordIsNotThisOnesAnswer() {
        let tuesday = monday.addingTimeInterval(day)
        let record = CKRecord(recordType: VerdictRecordSchema.recordType, recordID: CKRecord.ID(recordName: "verdict-alert"))
        XCTAssertFalse(SortRequests.isOfEarlierNotification(record, than: tuesday), "nothing to go by")

        record[VerdictRecordSchema.deliveredAt] = monday
        XCTAssertTrue(SortRequests.isOfEarlierNotification(record, than: tuesday), "asked about on Monday, never answered")
        XCTAssertFalse(SortRequests.isOfEarlierNotification(record, than: monday.addingTimeInterval(2)), "another Mac asked first")

        record[VerdictRecordSchema.triagedAt] = monday.addingTimeInterval(1)
        XCTAssertTrue(SortRequests.isOfEarlierNotification(record, than: tuesday))

        // The iPhone sorted Tuesday's itself, onto the record Monday's request made.
        record[VerdictRecordSchema.triagedAt] = tuesday.addingTimeInterval(1)
        XCTAssertFalse(SortRequests.isOfEarlierNotification(record, than: tuesday))
        XCTAssertFalse(SortRequests.isOfEarlierNotification(record, than: monday), "a later one's: left alone")
    }

    /// A repeat is asked about under a name of its own, a new record each time, which
    /// is what wakes the iPhone; and it's a request, not a verdict a Mac would take up.
    func testARepeatIsAskedAboutUnderItsOwnName() {
        let (inbox, suite) = makeInbox()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        inbox.add(alert(1, at: monday), as: .spark)
        inbox.add(alert(2, at: monday.addingTimeInterval(day)), as: .spark)
        inbox.markRead(ids: ["notification-2"], at: monday.addingTimeInterval(day + 17))
        let requests = inbox.items.map(SortRequests.Request.init)
        let names = requests.map(SortRequests.repeatRecordName)
        let fingerprint = Inbox.fingerprint(for: alert(1, at: monday), as: .spark)
        XCTAssertEqual(Set(requests.map(\.fingerprint)), [fingerprint])
        XCTAssertEqual(Set(names).count, 2)
        for name in names {
            XCTAssertTrue(name.hasPrefix(VerdictRecordSchema.recordName(fingerprint: fingerprint) + "@"))
            XCTAssertNotEqual(VerdictRecordSchema.fingerprint(recordName: name), fingerprint)
        }

        let tuesdays = SortRequests.record(for: requests[0], named: names[0], now: monday.addingTimeInterval(day + 120))
        XCTAssertEqual(tuesdays[VerdictRecordSchema.deliveredAt] as? Date, monday.addingTimeInterval(day))
        XCTAssertEqual(tuesdays[VerdictRecordSchema.readAt] as? Date, monday.addingTimeInterval(day + 17), "read here: filed without an alert")
        XCTAssertNotNil(tuesdays[VerdictRecordSchema.sortRequestedAt])
        XCTAssertNil(VerdictStore.verdict(from: tuesdays))
    }
}
