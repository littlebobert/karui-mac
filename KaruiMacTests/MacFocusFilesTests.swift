import XCTest
@testable import KaruiMac

/// The Focus that's on, from macOS's Focus files, shaped as macOS 27 writes them.
final class MacFocusFilesTests: XCTestCase {
    private let karuiFocus = "com.apple.donotdisturb.mode.globeeuropeafricafill"
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        // 2026-10-25 is a Sunday (weekday 1).
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 24 + weekday, hour: hour, minute: minute))!
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func assertions(_ records: [(mode: String, start: Double)]) -> Data {
        json(["data": [["storeAssertionRecords": records.map { [
            "assertionStartDateTimestamp": $0.start,
            "assertionDetails": ["assertionDetailsModeIdentifier": $0.mode],
        ] }]], "header": ["version": 8]])
    }

    private func configurations(schedule: [String: Any]? = nil) -> Data {
        var work: [String: Any] = ["mode": ["name": "Work", "modeIdentifier": "com.apple.focus.work"]]
        if let schedule { work["triggers"] = ["triggers": [schedule]] }
        return json(["data": [["modeConfigurations": [
            karuiFocus: ["mode": ["name": "Karui", "modeIdentifier": karuiFocus], "triggers": ["triggers": [["class": "DNDModeConfigurationSmartTrigger", "enabledSetting": 1]]]],
            "com.apple.focus.work": work,
        ]]]])
    }

    private func schedule(_ start: Int, _ end: Int, weekdays: Int = 127, enabled: Int = 2) -> [String: Any] {
        ["class": "DNDModeConfigurationScheduleTrigger", "enabledSetting": enabled, "timePeriodStartTimeHour": start, "timePeriodStartTimeMinute": 0,
         "timePeriodEndTimeHour": end, "timePeriodEndTimeMinute": 0, "timePeriodWeekdays": weekdays]
    }

    func testTheNewestAssertionIsTheFocusOn() {
        XCTAssertEqual(MacFocusFiles.activeModeIdentifier(assertions: assertions([("com.apple.focus.work", 100), (karuiFocus, 200)])), karuiFocus)
        XCTAssertNil(MacFocusFiles.activeModeIdentifier(assertions: assertions([])))
        XCTAssertNil(MacFocusFiles.activeModeIdentifier(assertions: Data("not json".utf8)))
    }

    func testAScheduledFocus() {
        let config = configurations(schedule: schedule(9, 17))
        XCTAssertEqual(MacFocusFiles.scheduledModeIdentifier(configurations: config, now: date(weekday: 2, hour: 10), calendar: calendar), "com.apple.focus.work")
        XCTAssertNil(MacFocusFiles.scheduledModeIdentifier(configurations: config, now: date(weekday: 2, hour: 17), calendar: calendar), "ends at 17:00")
        XCTAssertNil(MacFocusFiles.scheduledModeIdentifier(configurations: configurations(schedule: schedule(9, 17, enabled: 0)), now: date(weekday: 2, hour: 10), calendar: calendar), "turned off")
        // Weekdays only: Monday to Friday, Sunday the lowest bit.
        let weekdays = configurations(schedule: schedule(9, 17, weekdays: 0b0111110))
        XCTAssertEqual(MacFocusFiles.scheduledModeIdentifier(configurations: weekdays, now: date(weekday: 6, hour: 10), calendar: calendar), "com.apple.focus.work")
        XCTAssertNil(MacFocusFiles.scheduledModeIdentifier(configurations: weekdays, now: date(weekday: 1, hour: 10), calendar: calendar), "Sunday")
    }

    /// 22:00 to 07:00: on after midnight too, as part of the day it started.
    func testAnOvernightSchedule() {
        let fridayNights = configurations(schedule: schedule(22, 7, weekdays: 1 << 5))
        XCTAssertEqual(MacFocusFiles.scheduledModeIdentifier(configurations: fridayNights, now: date(weekday: 6, hour: 23), calendar: calendar), "com.apple.focus.work")
        XCTAssertEqual(MacFocusFiles.scheduledModeIdentifier(configurations: fridayNights, now: date(weekday: 7, hour: 3), calendar: calendar), "com.apple.focus.work", "Saturday morning")
        XCTAssertNil(MacFocusFiles.scheduledModeIdentifier(configurations: fridayNights, now: date(weekday: 7, hour: 23), calendar: calendar), "Saturday night")
    }

    func testTheFocusAndWhatItLetsThrough() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacFocusFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(MacFocusFiles.activeFocus(in: directory), "no files: no Focus")
        XCTAssertNil(MacFocusFiles.anyFocusAllows("com.example.karui.mac", in: directory))

        try assertions([(karuiFocus, 200)]).write(to: directory.appending(path: "Assertions.json"))
        try configurations().write(to: directory.appending(path: "ModeConfigurations.json"))
        try json(["data": [["secureModeConfigurations": [
            karuiFocus: ["secureConfiguration": ["allowedApplications": ["com.example.karui.mac": [:], "com.tinyspeck.slackmacgap": [:]]]]],
        ]]]).write(to: directory.appending(path: "ModeConfigurationsSecure.json"))

        let focus = MacFocusFiles.activeFocus(in: directory)
        XCTAssertEqual(focus?.identifier, karuiFocus)
        XCTAssertEqual(focus?.name, "Karui")
        XCTAssertEqual(focus?.allowedApps, ["com.example.karui.mac", "com.tinyspeck.slackmacgap"])
        XCTAssertTrue(MacRepost.isKaruisFocus(focus, karuiID: "com.example.karui.mac"))
        XCTAssertFalse(MacRepost.isKaruisFocus(focus, karuiID: "com.example.other"))
        XCTAssertEqual(MacFocusFiles.anyFocusAllows("com.example.karui.mac", in: directory), true)
        XCTAssertEqual(MacFocusFiles.anyFocusAllows("com.example.other", in: directory), false)
    }
}
