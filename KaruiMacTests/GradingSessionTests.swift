import XCTest
@testable import KaruiMac

@MainActor
final class GradingSessionTests: XCTestCase {
    private var folder: URL!
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private var macHistory: [GradingSession.Item] = []

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "GradingSessionTests-\(UUID().uuidString)")
        macHistory = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func session() -> GradingSession {
        GradingSession(folder: folder, now: { [now] in now }, macHistory: { [unowned self] in macHistory })
    }

    private func triagedAt(daysAgo: Double) -> Date {
        now.addingTimeInterval(-daysAgo * 86_400)
    }

    /// A line as the iPhone's `HistoryExport` writes it, with fields grading ignores.
    private func line(
        _ body: String = UUID().uuidString,
        category: String = "summary",
        daysAgo: Double = 1,
        originalCategory: String? = nil,
        triggers: [String] = ["originalNotification"]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": UUID().uuidString,
            "triagedAt": ISO8601DateFormatter().string(from: triagedAt(daysAgo: daysAgo)),
            "source": "Messages",
            "sender": "Aya",
            "title": "Aya",
            "body": body,
            "category": category,
            "reason": "A question to the user",
            "confidence": 0.8,
            "engine": "onDeviceModel",
            "decidedBy": triggers.last ?? "originalNotification",
            "triggers": triggers,
            "isFromVIP": false,
        ]
        if let originalCategory { object["originalCategory"] = originalCategory }
        return object
    }

    /// This Mac's copy of an item, as the inbox gives it.
    private func macItem(_ body: String = UUID().uuidString, category: String = "summary", daysAgo: Double = 1) -> GradingSession.Item {
        GradingSession.Item(
            line: GradingSession.ExportLine(
                triagedAt: triagedAt(daysAgo: daysAgo), source: "Messages", sender: "Aya",
                title: "Aya", body: body, category: category, reason: "A question to the user"
            ),
            origin: .mac,
            raw: nil
        )
    }

    private func importLines(_ lines: [[String: Any]], into session: GradingSession) throws {
        let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let url = folder.appending(path: "export-\(UUID().uuidString).jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url)
        session.importHistory(from: [url])
    }

    /// The golden set starts with what was fixed or changed, then the categories take turns.
    func testGoldenQueuePutsRevisedItemsFirstThenInterleaves() throws {
        let session = session()
        try importLines([
            line(category: "summary"), line(category: "summary"), line(category: "summary"),
            line(category: "silence"), line(category: "notifyNow"),
            line("fixed", category: "notifyNow", triggers: ["originalNotification", "correction"]),
            line("overridden", category: "silence", originalCategory: "summary", triggers: ["originalNotification", "cloudSecondOpinion"]),
        ], into: session)

        let queue = session.candidates(for: .golden)
        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(Set(queue.prefix(2).map(\.line.body)), ["fixed", "overridden"])
        XCTAssertEqual(queue.dropFirst(2).prefix(3).map(\.line.category), ["notifyNow", "summary", "silence"])
    }

    /// A second opinion that agreed changed nothing, so it isn't a hard case.
    func testAnAgreeingSecondOpinionIsNotRevised() throws {
        let session = session()
        try importLines([line(triggers: ["originalNotification", "cloudSecondOpinion"])], into: session)
        XCTAssertFalse(try XCTUnwrap(session.current).wasRevised)
    }

    /// What the rules decided is no prompt's doing, so the golden set leaves it out;
    /// a spot check still shows it, since a rule's mistake is a miss too.
    func testGoldenSetLeavesOutWhatTheRulesDecided() throws {
        let session = session()
        var rules = line("from a VIP")
        rules["engine"] = "Transparent rules"
        var cloud = line("asked the cloud")
        cloud["engine"] = "Private Cloud Compute"
        try importLines([rules, cloud], into: session)
        XCTAssertEqual(session.candidates(for: .golden).map(\.line.body), ["asked the cloud"])
        XCTAssertEqual(session.ruleDecidedCount, 1)
        XCTAssertEqual(Set(session.candidates(for: .spotCheck).map(\.line.body)), ["from a VIP", "asked the cloud"])
    }

    /// With the first sort's engine, a rules answer later fixed is still left out, and a
    /// fallback the model should have given stays in.
    func testTheFirstSortDecidesWhatTheRulesDecided() throws {
        let session = session()
        var fixedRules = line("a VIP, fixed", originalCategory: "notifyNow", triggers: ["originalNotification", "correction"])
        fixedRules["engine"] = "Your correction"
        fixedRules["firstEngine"] = "Transparent rules"
        fixedRules["firstWasModelFallback"] = false
        var fallback = line("the model timed out")
        fallback["engine"] = "Transparent rules"
        fallback["firstEngine"] = "Transparent rules"
        fallback["firstWasModelFallback"] = true
        try importLines([fixedRules, fallback], into: session)
        XCTAssertEqual(session.candidates(for: .golden).map(\.line.body), ["the model timed out"])
        XCTAssertEqual(session.ruleDecidedCount, 1)
    }

    /// Spot checks are the past week's Neutral and Spam that no one fixed.
    func testSpotCheckTakesRecentUnfixedNeutralAndSpam() throws {
        let session = session()
        try importLines([
            line("neutral", category: "summary"),
            line("spam", category: "silence", daysAgo: 6),
            line(category: "notifyNow"),
            line(category: "summary", daysAgo: 8),
            line(category: "summary", triggers: ["originalNotification", "correction"]),
        ], into: session)
        XCTAssertEqual(Set(session.candidates(for: .spotCheck).map(\.line.body)), ["neutral", "spam"])
    }

    /// Grades and History survive a relaunch; a later export replaces a line and keeps its grade.
    func testGradesPersistAndReimportKeepsThem() throws {
        let first = session()
        try importLines([line("call me", category: "summary")], into: first)
        first.grade(.important)

        let second = session()
        XCTAssertEqual(second.latestGrades.values.first?.label, .important)
        XCTAssertEqual(second.tally().compared, 1)
        XCTAssertEqual(second.tally().agreed, 0)

        try importLines([line("call me", category: "notifyNow", originalCategory: "summary", triggers: ["originalNotification", "correction"])], into: second)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertEqual(second.tally().agreed, 1)
        XCTAssertNil(second.current)
    }

    /// This Mac's History is graded without any import.
    func testMacHistoryNeedsNoImport() {
        macHistory = [macItem("from the Mac")]
        let session = session()
        XCTAssertEqual(session.current?.line.body, "from the Mac")
        XCTAssertEqual(session.current?.origin, .mac)
    }

    /// An item in both this Mac's History and an export is one item: the export's line,
    /// which knows more, and a grade given to either copy.
    func testAnItemInBothSourcesIsGradedOnce() throws {
        macHistory = [macItem("see you at 7"), macItem("another")]
        let session = session()
        while session.current?.line.body != "see you at 7" { session.skip() }
        session.grade(.neutral)

        try importLines([line("see you at 7", originalCategory: "notifyNow", triggers: ["originalNotification", "correction"])], into: session)
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items.values.first { $0.line.body == "see you at 7" }?.origin, .export)
        XCTAssertEqual(session.candidates(for: .golden).map(\.line.body), ["another"])
        XCTAssertEqual(session.tally().agreed, 1)
    }

    /// Verdicts that reach the inbox later show up when the window comes back.
    func testRefreshPicksUpNewMacHistory() {
        let session = session()
        XCTAssertNil(session.current)
        macHistory = [macItem()]
        session.refreshMacHistory()
        XCTAssertNotNil(session.current)
    }

    /// Skipped items wait at the end; undo brings the last graded item back first.
    func testSkipAndUndo() throws {
        let session = session()
        try importLines([line(), line(), line()], into: session)
        let first = try XCTUnwrap(session.current)
        session.skip()
        XCTAssertNotEqual(session.current?.id, first.id)
        XCTAssertEqual(session.candidates(for: .golden).last?.id, first.id)

        let graded = try XCTUnwrap(session.current)
        session.grade(.spam)
        XCTAssertNotEqual(session.current?.id, graded.id)
        session.undo()
        XCTAssertEqual(session.current?.id, graded.id)
        XCTAssertTrue(session.grades.isEmpty)
    }

    /// Unclear grades count but aren't compared with Karui's category.
    func testUnclearIsNotCompared() throws {
        let session = session()
        try importLines([line(), line()], into: session)
        session.grade(.unclear)
        session.grade(.neutral)
        let tally = session.tally()
        XCTAssertEqual(tally.counts[.unclear], 1)
        XCTAssertEqual(tally.compared, 1)
        XCTAssertEqual(tally.agreed, 1)
    }

    /// The golden set is each export line as it came, or this Mac's copy in the same
    /// shape, plus where it came from and the grade.
    func testGoldenSetKeepsTheLineAndAddsTheLabel() throws {
        macHistory = [macItem("from the Mac", daysAgo: 2)]
        let session = session()
        try importLines([line("exported")], into: session)
        session.queue = .spotCheck
        while session.current != nil { session.grade(.important) }

        let objects = try session.goldenSet().split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(objects.count, 2)
        let exported = try XCTUnwrap(objects.first { $0["body"] as? String == "exported" })
        XCTAssertEqual(exported["origin"] as? String, "export")
        XCTAssertEqual(exported["engine"] as? String, "onDeviceModel")
        XCTAssertEqual(exported["category"] as? String, "summary")
        XCTAssertEqual(exported["label"] as? String, "notifyNow")
        XCTAssertEqual(exported["labelQueue"] as? String, "spotCheck")
        XCTAssertNotNil(exported["gradedAt"])
        let mac = try XCTUnwrap(objects.first { $0["body"] as? String == "from the Mac" })
        XCTAssertEqual(mac["origin"] as? String, "mac")
        XCTAssertEqual(mac["title"] as? String, "Aya")
        XCTAssertNotNil(mac["triagedAt"])
        XCTAssertNil(mac["id"])
    }
}
