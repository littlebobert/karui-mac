import XCTest
@testable import KaruiSorting

/// A sender silenced from History is Spam in that app, whatever the model said.
final class SilencedSendersTests: XCTestCase {
    private func email(from sender: String?, in source: String = "Spark") -> NotificationInput {
        NotificationInput(source: source, title: "Nextdoor", body: "Justin, see your unread notifications", sender: sender)
    }

    private let important = TriageResult(
        category: .notifyNow, confidence: 0.9, reason: "Addressed to Justin by name", engine: .privateCloudCompute, interest: 4
    )

    func testASilencedSendersNotificationIsSpam() {
        var policy = TriagePolicy.standard
        policy.addSilencedSender("Nextdoor", in: "Spark")
        let result = SilencedSenders.applying(to: important, for: email(from: "nextdoor"), policy: policy, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(result.category, .silence)
        XCTAssertEqual(result.reason, "From a sender you silenced.")
        XCTAssertEqual(result.engine, .privateCloudCompute)
        XCTAssertEqual(result.interest, 4)
    }

    func testOnlyInTheAppTheyWereSilencedIn() {
        var policy = TriagePolicy.standard
        policy.addSilencedSender("Nextdoor", in: "Spark")
        XCTAssertEqual(SilencedSenders.applying(to: important, for: email(from: "Nextdoor", in: "Nextdoor"), policy: policy).category, .notifyNow)
        XCTAssertEqual(SilencedSenders.applying(to: important, for: email(from: nil), policy: policy).category, .notifyNow)
        XCTAssertEqual(SilencedSenders.applying(to: important, for: email(from: "Michelle"), policy: policy).category, .notifyNow)
    }

    func testAVIPIsNeverSilenced() {
        var policy = TriagePolicy.standard
        policy.addSilencedSender("Sam", in: "LINE")
        policy.addPromotedSender("Sam")
        let message = NotificationInput(source: "LINE", title: "Sam", body: "Call me", sender: "Sam")
        XCTAssertEqual(SilencedSenders.applying(to: important, for: message, policy: policy).category, .notifyNow)
    }

    func testAddingTwiceKeepsOneAndRemovingTakesIt() {
        var policy = TriagePolicy.standard
        policy.addSilencedSender(" Nextdoor ", in: "Spark")
        policy.addSilencedSender("NEXTDOOR", in: "Spark")
        policy.addSilencedSender("Nextdoor", in: " ")
        XCTAssertEqual(policy.silencedSenders, [SilencedSender(name: "Nextdoor", app: "Spark")])
        policy.removeSilencedSender("nextdoor", in: "Spark")
        XCTAssertTrue(policy.silencedSenders.isEmpty)
    }

    func testTheNameShowsWithoutTheEmailAddress() {
        XCTAssertEqual(SilencedSender.displayName("BrightBox Deals <offers@brightbox.example>"), "BrightBox Deals")
        XCTAssertEqual(SilencedSender.displayName("\"Nextdoor\" <reply@rs.email.nextdoor.com>"), "Nextdoor")
        XCTAssertEqual(SilencedSender.displayName("<offers@brightbox.example>"), "<offers@brightbox.example>")
        XCTAssertEqual(SilencedSender.displayName("Nextdoor"), "Nextdoor")
    }

    func testTheListSurvivesEncodingAndOlderSettingsHaveNone() throws {
        var policy = TriagePolicy.standard
        policy.addSilencedSender("Nextdoor", in: "Spark")
        let decoded = try JSONDecoder().decode(TriagePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(decoded.silencedSenders, policy.silencedSenders)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TriagePolicy.standard)) as? [String: Any])
        json["silencedSenders"] = nil
        let older = try JSONDecoder().decode(TriagePolicy.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(older.silencedSenders, [])
    }
}
