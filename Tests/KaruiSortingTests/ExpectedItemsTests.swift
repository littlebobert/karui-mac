import XCTest
@testable import KaruiSorting

/// What the person told Karui they're waiting for: in both prompts while it's active,
/// Important when a model says a notification is it, and left alone by the rules
/// that lower an Important.
final class ExpectedItemsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")
    private let delivery = NotificationInput(source: "Amazon", title: "Out for delivery", body: "Your package arrives today by 8 PM.")
    private let neutral = TriageResult(
        category: .summary, confidence: 0.8, reason: "A delivery update", engine: .onDeviceModel, interest: 4
    )

    private func policy(expecting texts: [String], lasting duration: ExpectedItemDuration = .untilArrival) -> TriagePolicy {
        var policy = TriagePolicy.standard
        for text in texts { policy.addExpectedItem(text, lasting: duration, now: now) }
        return policy
    }

    func testNothingExpectedLeavesThePromptsAsTheyWere() {
        let policy = TriagePolicy.standard
        XCTAssertNil(ExpectedItems.promptSection(for: policy, now: now))
        let prompt = SecondOpinionPrompt.prompt(for: delivery, policy: policy, correspondentMatch: { _ in nil }, now: now, locale: english)
        XCTAssertFalse(prompt.contains("Expect"))
        XCTAssertTrue(prompt.contains("Answer with exactly five lines"))
    }

    func testBothPromptsListWhatIsExpectedByNumber() throws {
        let policy = policy(expecting: ["A delivery from IKEA", "A call\nfrom the clinic"])
        let section = try XCTUnwrap(ExpectedItems.promptSection(for: policy, now: now))
        XCTAssertTrue(section.contains("1. A delivery from IKEA"))
        // One line each, so an item can't pose as another line of the prompt.
        XCTAssertTrue(section.contains("2. A call from the clinic"))

        let cloud = SecondOpinionPrompt.prompt(for: delivery, policy: policy, correspondentMatch: { _ in nil }, now: now, locale: english)
        XCTAssertTrue(cloud.contains(section))
        XCTAssertTrue(cloud.contains("Answer with exactly six lines"))
        XCTAssertTrue(cloud.contains("Expected: the number of the expected item"))

        guard #available(macOS 26.0, *) else { return }
        let environment = SortingEnvironment(
            calendarContext: { _ in "none" }, correspondentMatch: { _ in nil },
            applyingCorrections: { result, _, _ in result }, conditions: { ("test", "test") }
        )
        let onDevice = FoundationModelClassifier(environment: environment).modelInput(for: delivery, policy: policy, now: now, locale: english)
        XCTAssertTrue(onDevice.prompt.contains(section))
    }

    func testAnItemRunsOutAndItsNumberIsReused() {
        var policy = policy(expecting: ["A delivery"], lasting: .today)
        policy.addExpectedItem("Sam’s reply", lasting: .week, now: now)
        XCTAssertEqual(policy.activeExpectedItems(at: now).map(\.number), [1, 2])
        // Today's is over tomorrow; the week's still runs.
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(policy.activeExpectedItems(at: tomorrow).map(\.text), ["Sam’s reply"])
        // The next one takes the number that came free, not Sam's.
        let added = policy.addExpectedItem("A call", lasting: .untilArrival, now: tomorrow)
        XCTAssertEqual(added?.number, 1)
        XCTAssertEqual(policy.expectedItems.map(\.text), ["Sam’s reply", "A call"])
    }

    func testNoMoreThanTheLimitAndNothingEmpty() {
        var policy = policy(expecting: (1...ExpectedItems.limit).map { "Thing \($0)" })
        XCTAssertNil(policy.addExpectedItem("One more", lasting: .today, now: now))
        XCTAssertEqual(policy.expectedItems.count, ExpectedItems.limit)
        policy.removeExpectedItem(id: policy.expectedItems[0].id)
        XCTAssertNil(policy.addExpectedItem("   ", lasting: .today, now: now))
        XCTAssertNotNil(policy.addExpectedItem("One more", lasting: .today, now: now))
    }

    func testAModelsMatchIsImportantAndNamesTheItem() throws {
        let policy = policy(expecting: ["A delivery"])
        let item = try XCTUnwrap(policy.expectedItems.first)
        let result = ExpectedItems.applying(expected: 1, to: neutral, policy: policy, now: now, locale: english)
        XCTAssertEqual(result.category, .notifyNow)
        XCTAssertEqual(result.expectedItemID, item.id)
        XCTAssertEqual(result.expectedItemText, "A delivery")
        XCTAssertEqual(result.reason, "A delivery update")
        XCTAssertEqual(result.engine, .onDeviceModel)
        XCTAssertEqual(result.interest, 4)
    }

    func testNoMatchOrAnUnknownNumberChangesNothing() {
        let policy = policy(expecting: ["A delivery"])
        for number in [nil, 0, 2, -1] as [Int?] {
            XCTAssertEqual(ExpectedItems.applying(expected: number, to: neutral, policy: policy, now: now), neutral)
        }
        // Run out by the time the answer came.
        let nextMonth = now.addingTimeInterval(30 * 24 * 60 * 60)
        XCTAssertEqual(ExpectedItems.applying(expected: 1, to: neutral, policy: policy, now: nextMonth), neutral)
    }

    func testAQuietAppStillAlertsForWhatIsExpectedButASilencedSenderDoesNot() {
        var policy = policy(expecting: ["A delivery"])
        policy.quietApps = ["Amazon"]
        let expected = ExpectedItems.applying(expected: 1, to: neutral, policy: policy, now: now)
        XCTAssertEqual(QuietApps.applying(to: expected, for: delivery, policy: policy).category, .notifyNow)
        // The same Important without a match is quieted as ever.
        let important = TriageResult(category: .notifyNow, confidence: 0.8, reason: "A delivery update", engine: .onDeviceModel)
        XCTAssertEqual(QuietApps.applying(to: important, for: delivery, policy: policy).category, .summary)

        let fromSender = NotificationInput(source: "Spark", title: "Out for delivery", body: "Arrives today.", sender: "Shop")
        policy.addSilencedSender("Shop", in: "Spark")
        XCTAssertEqual(SilencedSenders.applying(to: expected, for: fromSender, policy: policy).category, .silence)
    }

    func testOnlyAnItemThatEndsOnArrivalEndsThen() throws {
        var policy = policy(expecting: ["A delivery"])
        policy.addExpectedItem("Anything about the apartment", lasting: .week, now: now)
        let ids = policy.expectedItems.map(\.id)
        XCTAssertFalse(policy.endExpectedItemOnArrival(id: ids[1]))
        XCTAssertTrue(policy.endExpectedItemOnArrival(id: ids[0]))
        XCTAssertEqual(policy.expectedItems.map(\.text), ["Anything about the apartment"])
    }

    func testAnItemThatRingsSaysSoAndRingsOnce() throws {
        var policy = policy(expecting: ["A delivery"])
        // Asked for when it's added, or switched on afterwards.
        let call = try XCTUnwrap(policy.addExpectedItem("A call from the clinic", lasting: .week, ringsAlarm: true, now: now))
        XCTAssertFalse(ExpectedItems.applying(expected: 1, to: neutral, policy: policy, now: now).expectedItemRingsAlarm)
        XCTAssertTrue(ExpectedItems.applying(expected: 2, to: neutral, policy: policy, now: now).expectedItemRingsAlarm)
        policy.setExpectedItem(id: policy.expectedItems[0].id, ringsAlarm: true)
        XCTAssertTrue(ExpectedItems.applying(expected: 1, to: neutral, policy: policy, now: now).expectedItemRingsAlarm)
        // The week-long one would ring at every match: it ends with the first.
        XCTAssertTrue(policy.endExpectedItemOnArrival(id: call.id))
        XCTAssertEqual(policy.expectedItems.map(\.text), ["A delivery"])
    }

    func testAnItemSavedBeforeAlarmsStillLoads() throws {
        let saved = policy(expecting: ["A delivery"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var items = try XCTUnwrap(object["expectedItems"] as? [[String: Any]])
        items[0]["ringsAlarm"] = nil
        object["expectedItems"] = items
        let older = try JSONDecoder().decode(TriagePolicy.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.expectedItems.map(\.text), ["A delivery"])
        XCTAssertEqual(older.expectedItems.first?.ringsAlarm, false)
        XCTAssertEqual(older.expectedItems.first?.id, saved.expectedItems.first?.id)
    }

    func testTheCloudsAnswerSaysWhichItem() {
        let lines = "Category: Important\nExpected: 2\nConfidence: 0.9\nInterest: 4\nReason: The clinic is calling\nTags: clinic, call"
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: lines)?.expected, 2)
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: lines)?.reason, "The clinic is calling")
        XCTAssertNil(SecondOpinionPrompt.parse(answer: "Category: Neutral\nExpected: None\nConfidence: 0.8\nReason: A receipt")?.expected)
        XCTAssertNil(SecondOpinionPrompt.parse(answer: "Category: Neutral\nConfidence: 0.8\nReason: A receipt")?.expected)
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: #"{"category": "Important", "expected": 1, "reason": "Out for delivery"}"#)?.expected, 1)
        XCTAssertNil(SecondOpinionPrompt.parse(answer: #"{"category": "Neutral", "expected": 0, "reason": "A receipt"}"#)?.expected)
    }

    func testAPolicySavedBeforeExpectingStillLoadsAndANewOneRoundTrips() throws {
        let saved = policy(expecting: ["A delivery"])
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(TriagePolicy.self, from: data).expectedItems, saved.expectedItems)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["expectedItems"] = nil
        let older = try JSONDecoder().decode(TriagePolicy.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.expectedItems, [])
    }
}
