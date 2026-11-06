import XCTest
@testable import KaruiSorting

final class EventReminderDetectorTests: XCTestCase {
    private func name(_ source: String, _ title: String, _ body: String) -> String? {
        EventReminderDetector.eventName(in: NotificationInput(source: source, title: title, body: body))
    }

    func testCalendarAlertsAreReminders() {
        XCTAssertEqual(name("Calendar", "Team Sync", "Today at 12:00\nmeet.google.com"), "Team Sync")
        XCTAssertEqual(name("Calendar", "Book Club", "Leave by 18:25 to get to Sam’s Bar, Shibuya"), "Book Club")
        XCTAssertEqual(name("Calendar", "Book Club", "Leave now to get to Sam’s Bar, Shibuya"), "Book Club")
        XCTAssertEqual(name("Calendar", "Hack Day", "It will take 1 hr, 5 min to get to Fab Cafe"), "Hack Day")
    }

    /// Spark's calendar alerts: a 📅 title, and a start time in the body.
    func testMailCalendarAlertsAreReminders() {
        XCTAssertEqual(name("Spark", "📅 pay rent", "Starts Tomorrow at 9:00"), "pay rent")
        XCTAssertEqual(name("Spark", "📅 Team Sync", "Starts in 10 minutes at 12:00"), "Team Sync")
    }

    /// An invitation or a reply to one may need an answer, but it isn't a reminder.
    func testInvitationsAreLeftToTheModel() {
        XCTAssertNil(name("Calendar", "Team Sync", "Invitation From sam@example.com October 26, 2026 at 16:00"))
        XCTAssertNil(name("Calendar", "Team Sync", "Sam accepted your invitation"))
    }

    func testOtherNotificationsAreNot() {
        XCTAssertNil(name("Spark", "Kotoba App Meeting", "Starts in 10 minutes at 12:00"), "only a 📅 title marks a mail app's calendar alert")
        XCTAssertNil(name("Slack", "📅 standup", "see you there"), "a 📅 in a chat title without a time")
        XCTAssertNil(name("Calendar", "Holidays in Japan", "Culture Day"), "no time, no travel")
        XCTAssertNil(name("Messages", "Mika", "Meeting at 12:00?"))
    }

    func testTheSettingTurnsTheRuleOff() throws {
        var policy = TriagePolicy.standard
        XCTAssertTrue(policy.alertEventReminders)
        policy.alertEventReminders = false
        let decoded = try JSONDecoder().decode(TriagePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(decoded.alertEventReminders)
    }

    /// Settings saved before the switch existed decode with it on.
    func testOlderSettingsDecodeWithTheRuleOn() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TriagePolicy.standard)) as! [String: Any]
        object.removeValue(forKey: "alertEventReminders")
        let decoded = try JSONDecoder().decode(TriagePolicy.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.alertEventReminders)
    }

    /// Decided before the model, on any device, like one-time codes.
    @available(macOS 26.0, iOS 26.0, *)
    func testTheClassifierAlertsWithoutAskingTheModel() async {
        let environment = SortingEnvironment(
            calendarContext: { _ in "" },
            correspondentMatch: { _ in nil },
            applyingCorrections: { result, _, _ in result },
            conditions: { ("test", "test") }
        )
        let result = await FoundationModelClassifier(environment: environment)
            .classify(NotificationInput(source: "Spark", title: "📅 Team Sync", body: "Starts in 10 minutes at 12:00"), policy: .standard)
        XCTAssertEqual(result.category, .notifyNow)
        XCTAssertEqual(result.engine, .deterministicRules)
        XCTAssertTrue(result.reason.contains("Team Sync"))
    }
}
