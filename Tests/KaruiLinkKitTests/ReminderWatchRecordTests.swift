import XCTest
@testable import KaruiLinkKit

final class ReminderWatchRecordTests: XCTestCase {
    func testRecordNameRoundTrips() {
        let id = UUID()
        let name = ReminderWatchRecord.recordName(reminderID: id)
        XCTAssertEqual(ReminderWatchRecord.reminderID(recordName: name), id)
        XCTAssertNil(ReminderWatchRecord.reminderID(recordName: "verdict-abc"))
        XCTAssertNil(ReminderWatchRecord.reminderID(recordName: "reminder-watch-not-a-uuid"))
    }

    func testWatchesOnlyAppsWhoseSentMessagesTheMacReads() {
        XCTAssertEqual(ReminderWatchRecord.watchedApps, ["Messages", "Spark"])
    }
}
