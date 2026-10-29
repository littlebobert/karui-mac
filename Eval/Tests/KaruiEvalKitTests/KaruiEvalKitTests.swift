import Foundation
import KaruiSorting
import XCTest
@testable import KaruiEvalKit

final class PromptTemplateTests: XCTestCase {
    private let item = GoldenItem(
        triagedAt: Date(timeIntervalSince1970: 1_792_000_000), source: "Slack", sender: "Mika",
        title: "#design-review", subtitle: "Mika", body: "@Sam can you look at the copy before Thursday?",
        category: "summary", label: "notifyNow"
    )

    private func policy(deadlines: Bool) -> TriagePolicy {
        var policy = TriagePolicy.standard
        policy.deadlineRemindersEnabled = deadlines
        return policy
    }

    private let locale = Locale(identifier: "en_US")

    /// The parts put back together are the shipping prompt, character for character,
    /// with deadlines asked for and without.
    func testTheShippingTemplateIsTheShippingPrompt() throws {
        for deadlines in [false, true] {
            let prompt = PromptSections.shippingPrompt(item: item, policy: policy(deadlines: deadlines), locale: locale)
            let sections = try PromptSections(prompt: prompt)
            XCTAssertEqual(sections.prompt, prompt)
            XCTAssertEqual(try PromptTemplate.shipping.render(sections), prompt)
            XCTAssertEqual(try PromptTemplate(name: "expanded", text: PromptTemplate.starter(sections: sections, expanded: true), description: "").render(sections), prompt)
            XCTAssertEqual(sections.answerLines.map(\.label), deadlines
                ? ["Category", "Confidence", "Reason", "Tags", "Task", "Due"]
                : ["Category", "Confidence", "Reason", "Tags"])
        }
    }

    /// A variant moves answer lines, the count follows, and a line with nothing to show goes.
    func testAVariantRearrangesTheAnswerAndCountsIt() throws {
        let template = PromptTemplate(name: "reason-first", text: """
            {{instructions}}

            {{policy}}

            {{notification}}

            Answer with exactly {{answer.count}} lines and nothing else:
            {{answer.Reason}}
            {{answer.Category}}
            {{answer.Confidence}}
            {{answer.Task}}
            {{answer.Due}}
            """, description: "")
        let sections = try PromptSections(item: item, policy: policy(deadlines: false), locale: locale)
        let rendered = try template.render(sections)
        XCTAssertTrue(rendered.hasSuffix("""
            Answer with exactly three lines and nothing else:
            Reason: the reason, in at most 20 words
            Category: Important, Neutral, or Spam
            Confidence: a number from 0.0 through 1.0
            """), rendered)
        XCTAssertTrue(rendered.hasPrefix(sections.instructions))
        XCTAssertTrue(try template.render(PromptSections(item: item, policy: policy(deadlines: true), locale: locale)).contains("exactly five lines"))
    }

    func testAnUnknownPlaceholderIsAMistake() throws {
        let sections = try PromptSections(item: item, policy: policy(deadlines: false), locale: locale)
        XCTAssertThrowsError(try PromptTemplate(name: "typo", text: "{{instructionz}}", description: "").render(sections))
        XCTAssertThrowsError(try PromptTemplate(name: "typo", text: "{{answer.Reasn}}", description: "").render(sections))
    }

    /// `#` lines at a variant file's top describe it and aren't sent.
    func testAVariantFilesDescription() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "no-tags-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# Without the Tags line,\n# to see what it costs.\n\n{{instructions}}\n".write(to: url, atomically: true, encoding: .utf8)
        let template = try PromptTemplate(contentsOf: url)
        XCTAssertEqual(template.description, "Without the Tags line, to see what it costs.")
        XCTAssertEqual(template.text, "{{instructions}}")
    }
}

final class RunnerTests: XCTestCase {
    private var cacheURL: URL!

    override func setUp() {
        cacheURL = FileManager.default.temporaryDirectory.appending(path: "karui-eval-cache-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func item(_ body: String, label: String) -> GoldenItem {
        GoldenItem(triagedAt: Date(timeIntervalSince1970: 1_792_000_000), source: "Messages", sender: "Aya", title: "Aya", body: body, category: "summary", label: label)
    }

    private func answer(_ category: String) -> String {
        "Category: \(category)\nConfidence: 0.8\nReason: because\nTags: test"
    }

    private func runner(_ items: [GoldenItem], runs: Int = 2, maxFailures: Int = 5, ask: @escaping (String) -> (answer: String, seconds: Double)?) throws -> Runner {
        Runner(items: items, policy: .standard, locale: Locale(identifier: "en_US"), runs: runs, cache: try AnswerCache(url: cacheURL), delay: 0, maxFailuresInARow: maxFailures, ask: ask)
    }

    private let reasonFirst = PromptTemplate(name: "reason-first", text: "{{instructions}}\n\n{{policy}}\n\n{{notification}}\n\nAnswer with exactly {{answer.count}} lines and nothing else:\n{{answer.Reason}}\n{{answer.Category}}", description: "")

    /// Every answer is asked once and cached; a second run asks nothing. Unclear
    /// items aren't asked about.
    func testAnswersAreCachedAndUnclearItemsSkipped() throws {
        var asked = 0
        let items = [item("Can you call me?", label: "notifyNow"), item("lol", label: "ambiguous")]
        let first = try runner(items) { _ in asked += 1; return (self.answer("Important"), 2) }
        var results = try first.prepare([.shipping, reasonFirst])
        XCTAssertEqual(results.map(\.items.count), [1, 1])
        XCTAssertEqual(first.uncached(results), 4)
        XCTAssertFalse(first.run(&results).stoppedEarly)
        XCTAssertEqual(asked, 4)
        XCTAssertEqual(results[0].items[0].majority, .notifyNow)

        let second = try runner(items) { _ in XCTFail("asked again"); return nil }
        var again = try second.prepare([.shipping, reasonFirst])
        XCTAssertEqual(second.uncached(again), 0)
        second.run(&again)
        XCTAssertTrue(again[1].items[0].outcomes.allSatisfy(\.wasCached))
    }

    /// When the Shortcut keeps failing it stops, every prompt with the same runs, and
    /// a failure isn't cached.
    func testStopsWhenTheShortcutKeepsFailing() throws {
        var calls = 0
        let items = (0..<4).map { item("message \($0)", label: "summary") }
        let runner = try runner(items, maxFailures: 3) { _ in
            calls += 1
            return calls <= 8 ? (self.answer("Neutral"), 1) : nil
        }
        var results = try runner.prepare([.shipping, reasonFirst])
        XCTAssertTrue(runner.run(&results).stoppedEarly)
        // Run 1 covers all four items under both prompts before run 2 starts.
        XCTAssertEqual(results.map { $0.items.map(\.outcomes.count) }, [[1, 1, 1, 1], [1, 1, 1, 1]])
        XCTAssertEqual(try AnswerCache(url: cacheURL).count, 8)
    }
}

final class ReportTests: XCTestCase {
    private func result(_ label: String, _ answers: [TriageCategory?]) -> ItemResult {
        var result = ItemResult(
            item: GoldenItem(triagedAt: .now, source: "Mail", title: label, body: "", category: "summary", label: label),
            index: 0, prompt: ""
        )
        result.outcomes = answers.enumerated().map { Outcome(category: $1, answer: "", seconds: Double($0 + 1), wasCached: false) }
        return result
    }

    func testMajorityTiesGoToTheEarliestRun() {
        XCTAssertEqual(result("summary", [.silence, .summary]).majority, .silence)
        XCTAssertEqual(result("summary", [.silence, .summary, .summary]).majority, .summary)
        XCTAssertNil(result("summary", [nil, nil]).majority)
        XCTAssertTrue(result("summary", [.silence, nil, .summary]).flips)
        XCTAssertFalse(result("summary", [.summary, nil, .summary]).flips)
    }

    func testMetrics() {
        let variant = VariantResult(template: .shipping, items: [
            result("notifyNow", [.notifyNow, .notifyNow]),
            result("notifyNow", [.silence, .silence]),
            result("summary", [.notifyNow, .summary, .notifyNow]),
            result("silence", [.silence, nil]),
            result("summary", []),
        ])
        let metrics = VariantMetrics(variant)
        XCTAssertEqual(metrics.scored, 4)
        XCTAssertEqual(metrics.unanswered, 1)
        XCTAssertEqual(metrics.accuracy, .init(part: 2, whole: 4))
        XCTAssertEqual(metrics.importantRecall, .init(part: 1, whole: 2))
        XCTAssertEqual(metrics.importantPrecision, .init(part: 1, whole: 2))
        XCTAssertEqual(metrics.spamPrecision, .init(part: 1, whole: 2))
        XCTAssertEqual(metrics.importantAsSpam, 1)
        XCTAssertEqual(metrics.unreadableAnswers, .init(part: 1, whole: 9))
        XCTAssertEqual(metrics.flips, .init(part: 1, whole: 3))
        XCTAssertEqual(metrics.confusion[.notifyNow]?[.silence], 1)
    }

    func testChangedItemsSayWhichWay() {
        let shipping = VariantResult(template: .shipping, items: [
            result("notifyNow", [.summary]), result("summary", [.summary]), result("silence", [.summary]), result("summary", [.summary]),
        ])
        let variant = VariantResult(template: .init(name: "v", text: "", description: ""), items: [
            result("notifyNow", [.notifyNow]), result("summary", [.silence]), result("silence", [.notifyNow]), result("summary", [.summary]),
        ])
        XCTAssertEqual(ChangedItem.between(shipping: shipping, variant: variant).map(\.kind), [.fixed, .broke, .stillWrong])
        let markdown = ReportWriter.markdown([shipping, variant], context: .init(goldenFile: "golden.jsonl", itemCount: 4, unclearCount: 0, runs: 1, backend: "Private Cloud Compute", progress: .init(), stoppedEarly: false))
        XCTAssertTrue(markdown.contains("**Fixed: 1**"))
        XCTAssertTrue(markdown.contains("| Accuracy | 50% (2/4) | 50% (2/4) |"))
    }
}

final class VariantFileTests: XCTestCase {
    private let item = GoldenItem(
        triagedAt: Date(timeIntervalSince1970: 1_792_000_000), source: "Messages", sender: "Aya",
        title: "Aya", body: "Are you still coming tonight?", category: "notifyNow", label: "notifyNow"
    )

    private var variants: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../variants").standardized
    }

    /// Each sample variant still renders against today's shipping prompt, and its
    /// `#-` lines still find what they leave out.
    func testTheSampleVariantsRender() throws {
        var policy = TriagePolicy.standard
        for deadlines in [false, true] {
            policy.deadlineRemindersEnabled = deadlines
            let sections = try PromptSections(item: item, policy: policy, locale: Locale(identifier: "en_US"))
            let files = try FileManager.default.contentsOfDirectory(at: variants, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }
            XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["reason-first.txt", "no-interest.txt", "no-calendar.txt"])
            for file in files {
                let rendered = try PromptTemplate(contentsOf: file).render(sections)
                XCTAssertNotEqual(rendered, sections.prompt, file.lastPathComponent)
            }
        }
        let sections = try PromptSections(item: item, policy: .standard, locale: Locale(identifier: "en_US"))
        let noInterest = try PromptTemplate(contentsOf: variants.appending(path: "no-interest.txt")).render(sections)
        XCTAssertFalse(noInterest.contains("interest"))
        XCTAssertEqual(noInterest.split(separator: "\n").count, sections.prompt.split(separator: "\n").count - 6)
    }

    func testARemovalThatMatchesNothingIsAMistake() throws {
        let sections = try PromptSections(item: item, policy: .standard, locale: Locale(identifier: "en_US"))
        let template = PromptTemplate(name: "stale", text: PromptTemplate.shippingText, description: "", removals: ["A rule that was rewritten"])
        XCTAssertThrowsError(try template.render(sections))
    }
}

final class AgreementTests: XCTestCase {
    private func result(_ label: String, _ answers: [TriageCategory?], title: String = "") -> ItemResult {
        var result = ItemResult(
            item: GoldenItem(triagedAt: Date(timeIntervalSince1970: 0), source: "Mail", title: title, body: "", category: "summary", label: label),
            index: 0, prompt: ""
        )
        result.outcomes = answers.map { Outcome(category: $0, answer: "", seconds: 1, wasCached: true) }
        return result
    }

    /// A stand-in's answers are kept apart from Private Cloud Compute's, whose keys
    /// stay as they were before there were other backends.
    func testTheCacheKeepsBackendsApart() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "karui-eval-agree-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = try AnswerCache(url: url)
        try cache.store(prompt: "p", run: 0, answer: "Category: Important", seconds: 1)
        try cache.store(prompt: "p", run: 0, namespace: "ollama:gemma", answer: "Category: Spam", seconds: 1)
        let reopened = try AnswerCache(url: url)
        XCTAssertEqual(reopened.entry(prompt: "p", run: 0)?.answer, "Category: Important")
        XCTAssertEqual(reopened.entry(prompt: "p", run: 0, namespace: "ollama:gemma")?.answer, "Category: Spam")
        XCTAssertNil(reopened.entry(prompt: "p", run: 0, namespace: "on-device:27"))
        XCTAssertEqual(AnswerCache.key(prompt: "p", run: 0), AnswerCache.key(prompt: "p", run: 0, namespace: nil))
    }

    /// Agreement is by majority answer on items both answered, and a variant's move
    /// under Private Cloud Compute is checked against the stand-in's.
    func testAgreementAndShifts() {
        let variant = PromptTemplate(name: "v", text: "", description: "")
        let pcc = [
            VariantResult(template: .shipping, items: [result("notifyNow", [.notifyNow], title: "a"), result("summary", [.notifyNow], title: "b"), result("silence", [.silence], title: "c")]),
            VariantResult(template: variant, items: [result("notifyNow", [.notifyNow], title: "a"), result("summary", [.summary], title: "b"), result("silence", [], title: "c")]),
        ]
        let standIn = [
            VariantResult(template: .shipping, items: [result("notifyNow", [.notifyNow], title: "a"), result("summary", [.notifyNow], title: "b"), result("silence", [.summary], title: "c")]),
            VariantResult(template: variant, items: [result("notifyNow", [.summary], title: "a"), result("summary", [.summary], title: "b"), result("silence", [.summary], title: "c")]),
        ]
        let agreement = Agreement(pcc: pcc, standIn: standIn)
        XCTAssertEqual(agreement.variants.map(\.compared), [3, 2])
        XCTAssertEqual(agreement.variants.map(\.agreed), [2, 1])
        XCTAssertEqual(agreement.variants[0].standInAccuracy, .init(part: 1, whole: 3))
        XCTAssertEqual(agreement.shifts.count, 1)
        XCTAssertEqual(agreement.shifts.first?.item.title, "b")
        XCTAssertEqual(agreement.shifts.first?.standInFollowed, true)
        XCTAssertTrue(agreement.markdown(standIn: "gemma", goldenFile: "g.jsonl").contains("**Same answer as Private Cloud Compute: 60% (3/5)**"))
    }
}

final class GoldenSetTests: XCTestCase {
    /// Lines as Export Golden Set writes them, extra keys and all.
    func testRuleDecidedItemsGoByTheFirstSortAndFallbacksStay() throws {
        let line = { (engines: String) in
            #"{"triagedAt":"2026-10-20T09:00:00Z","source":"Messages","title":"mom","body":"hi","category":"notifyNow","label":"notifyNow","origin":"export",\#(engines)}"#
        }
        let lines = [
            line(#""engine":"Transparent rules","firstEngine":"Transparent rules","firstWasModelFallback":false"#),
            line(#""engine":"Transparent rules","firstEngine":"Transparent rules","firstWasModelFallback":true"#),
            line(#""engine":"Your correction","firstEngine":"Transparent rules""#),
            line(#""engine":"Transparent rules","firstEngine":"On-device model""#),
            line(#""engine":"Transparent rules""#),
            line(#""engine":"On-device model""#),
        ]
        let url = FileManager.default.temporaryDirectory.appending(path: "golden-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        let items = try GoldenItem.load(from: url)
        XCTAssertEqual(items.map(\.isDecidedByRules), [true, false, true, false, true, false])
    }

    func testTheReportSaysHowManyTheRulesDecided() {
        let context = { (rules: Int) in
            ReportWriter.Context(goldenFile: "golden.jsonl", itemCount: 4, unclearCount: 1, ruleDecidedCount: rules, runs: 1, backend: "Private Cloud Compute", progress: .init(), stoppedEarly: false)
        }
        XCTAssertTrue(ReportWriter.markdown([], context: context(6)).contains("4 items (1 graded Unclear and 6 decided by the rules left out)"))
        XCTAssertTrue(ReportWriter.markdown([], context: context(0)).contains("4 items (1 graded Unclear left out)"))
    }
}
