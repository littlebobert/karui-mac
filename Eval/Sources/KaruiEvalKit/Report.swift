import Foundation
import KaruiSorting

/// How one prompt did against the grades, by each item's majority answer.
public struct VariantMetrics: Equatable, Sendable {
    public struct Ratio: Equatable, Sendable {
        public let part: Int
        public let whole: Int
        public var value: Double? { whole == 0 ? nil : Double(part) / Double(whole) }

        public var text: String {
            guard let value else { return "—" }
            return "\(value.formatted(.percent.precision(.fractionLength(0)))) (\(part)/\(whole))"
        }
    }

    public let name: String
    /// Graded items with at least one answer.
    public let scored: Int
    /// Graded items no run got an answer for yet.
    public let unanswered: Int
    public let accuracy: Ratio
    /// Of what you graded Important, how much the prompt called Important.
    public let importantRecall: Ratio
    /// Of what the prompt called Important, how much you graded Important.
    public let importantPrecision: Ratio
    public let spamPrecision: Ratio
    public let spamRecall: Ratio
    /// You graded it Important; the prompt called it Spam. The costliest mistake.
    public let importantAsSpam: Int
    public let unreadableAnswers: Ratio
    /// Items whose readable runs didn't all agree, of those with two or more.
    public let flips: Ratio
    public let medianSeconds: Double?
    public let p95Seconds: Double?
    /// Your grade → the prompt's majority answer (nil: nothing readable) → count.
    public let confusion: [TriageCategory: [TriageCategory?: Int]]

    public init(_ result: VariantResult) {
        let answered = result.items.filter { !$0.outcomes.isEmpty }
        func count(_ predicate: (ItemResult) -> Bool) -> Int { answered.filter(predicate).count }
        name = result.template.name
        scored = answered.count
        unanswered = result.items.count - answered.count
        accuracy = Ratio(part: count { $0.majority == $0.item.labelCategory }, whole: answered.count)
        importantRecall = Ratio(
            part: count { $0.item.labelCategory == .notifyNow && $0.majority == .notifyNow },
            whole: count { $0.item.labelCategory == .notifyNow }
        )
        importantPrecision = Ratio(
            part: count { $0.majority == .notifyNow && $0.item.labelCategory == .notifyNow },
            whole: count { $0.majority == .notifyNow }
        )
        spamPrecision = Ratio(
            part: count { $0.majority == .silence && $0.item.labelCategory == .silence },
            whole: count { $0.majority == .silence }
        )
        spamRecall = Ratio(
            part: count { $0.item.labelCategory == .silence && $0.majority == .silence },
            whole: count { $0.item.labelCategory == .silence }
        )
        importantAsSpam = count { $0.item.labelCategory == .notifyNow && $0.majority == .silence }
        let outcomes = answered.flatMap(\.outcomes)
        unreadableAnswers = Ratio(part: outcomes.filter { $0.category == nil }.count, whole: outcomes.count)
        let repeated = answered.filter { $0.outcomes.compactMap(\.category).count > 1 }
        flips = Ratio(part: repeated.filter(\.flips).count, whole: repeated.count)
        let seconds = outcomes.map(\.seconds).sorted()
        medianSeconds = Self.percentile(seconds, 0.5)
        p95Seconds = Self.percentile(seconds, 0.95)
        var confusion: [TriageCategory: [TriageCategory?: Int]] = [:]
        for item in answered {
            guard let label = item.item.labelCategory else { continue }
            confusion[label, default: [:]][item.majority, default: 0] += 1
        }
        self.confusion = confusion
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
}

/// An item a variant answered differently from the shipping prompt.
public struct ChangedItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Now matches your grade.
        case fixed
        /// Matched your grade before, doesn't now.
        case broke
        /// Different, and still not your grade.
        case stillWrong
    }

    public let item: GoldenItem
    public let shipping: TriageCategory?
    public let variant: TriageCategory?
    public let kind: Kind

    /// Items both prompts answered, whose majority answers differ.
    public static func between(shipping: VariantResult, variant: VariantResult) -> [ChangedItem] {
        zip(shipping.items, variant.items).compactMap { before, after in
            guard !before.outcomes.isEmpty, !after.outcomes.isEmpty, before.majority != after.majority else { return nil }
            let label = before.item.labelCategory
            let kind: Kind = after.majority == label ? .fixed : before.majority == label ? .broke : .stillWrong
            return ChangedItem(item: before.item, shipping: before.majority, variant: after.majority, kind: kind)
        }
    }
}

public enum ReportWriter {
    public struct Context: Sendable {
        public var goldenFile: String
        public var itemCount: Int
        public var unclearCount: Int
        /// Graded items left out before the run because the rules decided them.
        public var ruleDecidedCount: Int
        public var runs: Int
        /// `Backend.name`.
        public var backend: String
        public var progress: Runner.Progress
        public var stoppedEarly: Bool
        public var date: Date

        public init(goldenFile: String, itemCount: Int, unclearCount: Int, ruleDecidedCount: Int = 0, runs: Int, backend: String, progress: Runner.Progress, stoppedEarly: Bool, date: Date = .now) {
            self.goldenFile = goldenFile
            self.itemCount = itemCount
            self.unclearCount = unclearCount
            self.ruleDecidedCount = ruleDecidedCount
            self.runs = runs
            self.backend = backend
            self.progress = progress
            self.stoppedEarly = stoppedEarly
            self.date = date
        }
    }

    public static func markdown(_ results: [VariantResult], context: Context) -> String {
        let metrics = results.map(VariantMetrics.init)
        var lines = [
            "# karui-eval, \(context.date.formatted(date: .abbreviated, time: .shortened))",
            "",
            "Golden set: \(context.goldenFile), \(context.itemCount) items (\(context.unclearCount) graded Unclear\(context.ruleDecidedCount > 0 ? " and \(context.ruleDecidedCount) decided by the rules" : "") left out) · \(context.runs) run\(context.runs == 1 ? "" : "s") each · \(context.backend)",
            "Answers: \(context.progress.cached) cached, \(context.progress.asked) asked now, \(context.progress.failed) failed",
        ]
        if context.stoppedEarly {
            lines.append("")
            lines.append("**Stopped early:** \(context.progress.failed) requests failed, for Private Cloud Compute most likely Apple’s limit. Everything answered is cached; run again later to fill in the rest.")
        }
        let names = metrics.map(\.name)
        func row(_ title: String, _ value: (VariantMetrics) -> String) -> String {
            "| \(title) | " + metrics.map(value).joined(separator: " | ") + " |"
        }
        func seconds(_ value: Double?) -> String {
            value.map { $0.formatted(.number.precision(.fractionLength(1))) + " s" } ?? "—"
        }
        lines += [
            "",
            "| | " + names.joined(separator: " | ") + " |",
            "|---|" + names.map { _ in "---|" }.joined(),
            row("Items scored") { "\($0.scored)" + ($0.unanswered > 0 ? " (\($0.unanswered) unanswered)" : "") },
            row("Accuracy") { $0.accuracy.text },
            row("Important recall") { $0.importantRecall.text },
            row("Important precision") { $0.importantPrecision.text },
            row("Spam precision") { $0.spamPrecision.text },
            row("Spam recall") { $0.spamRecall.text },
            row("Important called Spam") { "\($0.importantAsSpam)" },
            row("Unreadable answers") { $0.unreadableAnswers.text },
            row("Items that flip between runs") { $0.flips.text },
            row("Latency, median / p95") { "\(seconds($0.medianSeconds)) / \(seconds($0.p95Seconds))" },
        ]

        for metric in metrics {
            lines += ["", "## \(metric.name)"]
            if let template = results.first(where: { $0.template.name == metric.name })?.template, !template.description.isEmpty {
                lines += ["", template.description]
            }
            lines += [
                "",
                "Rows are your grade; columns, the prompt’s majority answer.",
                "",
                "| | Important | Neutral | Spam | Unreadable |",
                "|---|---|---|---|---|",
            ]
            for label in TriageCategory.allCases {
                let counts = metric.confusion[label] ?? [:]
                lines.append("| \(title(label)) | " + ([.notifyNow, .summary, .silence, nil] as [TriageCategory?]).map { "\(counts[$0] ?? 0)" }.joined(separator: " | ") + " |")
            }
        }

        if let shipping = results.first {
            for variant in results.dropFirst() {
                let changed = ChangedItem.between(shipping: shipping, variant: variant)
                lines += ["", "## \(variant.template.name) vs \(shipping.template.name)", ""]
                if changed.isEmpty {
                    lines.append("No item’s majority answer changed.")
                    continue
                }
                for (kind, heading) in [(ChangedItem.Kind.fixed, "Fixed"), (.broke, "Broke"), (.stillWrong, "Changed, still not your grade")] {
                    let items = changed.filter { $0.kind == kind }
                    guard !items.isEmpty else { continue }
                    lines += ["", "**\(heading): \(items.count)**", ""]
                    lines += items.map {
                        "- \(title($0.shipping)) → \(title($0.variant)), yours \(title($0.item.labelCategory)): \($0.item.summary)"
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line per item and prompt, with every run's answer, for a closer look.
    public static func jsonLines(_ results: [VariantResult]) throws -> Data {
        struct Line: Encodable {
            let variant: String
            let summary: String
            let label: String
            let majority: String?
            let runs: [String?]
            let answers: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for variant in results {
            for item in variant.items {
                let line = Line(
                    variant: variant.template.name, summary: item.item.summary, label: item.item.label,
                    majority: item.majority?.rawValue, runs: item.outcomes.map { $0.category?.rawValue }, answers: item.outcomes.map(\.answer)
                )
                data.append(try encoder.encode(line))
                data.append(0x0A)
            }
        }
        return data
    }

    static func title(_ category: TriageCategory?) -> String {
        switch category {
        case .notifyNow: "Important"
        case .summary: "Neutral"
        case .silence: "Spam"
        case nil: "Unreadable"
        }
    }
}
