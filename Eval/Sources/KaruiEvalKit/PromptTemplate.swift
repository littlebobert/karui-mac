import Foundation
import KaruiSorting

/// The shipping Second Opinion prompt for one notification, in the parts a variant
/// can rearrange. Split from `SecondOpinionPrompt.prompt` itself, so a variant
/// changes only what it names and the rest stays as the iPhone sends it.
public struct PromptSections: Equatable, Sendable {
    /// The rules, examples, and interest scale, with the deadline instructions when
    /// deadline reminders are on.
    public var instructions: String
    /// From "User policy:" to the line before "Notification:".
    public var policy: String
    /// From "Notification:" on, with the Dates line when deadlines are asked for.
    public var notification: String
    /// "Answer with exactly four lines and nothing else:" and the lines it asks for.
    public var answerHeader: String
    /// Each answer line by its label: Category, Confidence, Reason, Tags, and Task
    /// and Due when deadlines are asked for.
    public var answerLines: [(label: String, line: String)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instructions == rhs.instructions && lhs.policy == rhs.policy && lhs.notification == rhs.notification
            && lhs.answerHeader == rhs.answerHeader
            && lhs.answerLines.map(\.label) == rhs.answerLines.map(\.label)
            && lhs.answerLines.map(\.line) == rhs.answerLines.map(\.line)
    }

    public var answer: String {
        ([answerHeader] + answerLines.map(\.line)).joined(separator: "\n")
    }

    /// The prompt as shipped, put back together.
    public var prompt: String {
        [instructions, policy, notification, answer].joined(separator: "\n\n")
    }

    public init(prompt: String) throws {
        func split(_ text: String, at marker: String) throws -> (String, String) {
            guard let range = text.range(of: marker) else {
                throw EvalError("The Second Opinion prompt no longer has “\(marker.trimmingCharacters(in: .newlines))”; PromptSections needs updating.")
            }
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        let (instructions, afterInstructions) = try split(prompt, at: "\n\nUser policy:\n")
        let (policy, afterPolicy) = try split(afterInstructions, at: "\n\nNotification:\n")
        let (notification, afterNotification) = try split(afterPolicy, at: "\n\nAnswer with exactly ")
        let answer = afterNotification.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = answer.first else { throw EvalError("The Second Opinion prompt has no answer lines.") }
        self.instructions = instructions
        self.policy = "User policy:\n" + policy
        self.notification = "Notification:\n" + notification
        answerHeader = "Answer with exactly " + header
        answerLines = try answer.dropFirst().map { line in
            guard let colon = line.firstIndex(of: ":") else {
                throw EvalError("An answer line has no label: \(line)")
            }
            return (String(line[..<colon]), line)
        }
    }

    /// The shipping prompt for this item and policy, split.
    public init(item: GoldenItem, policy: TriagePolicy, locale: Locale) throws {
        try self.init(prompt: Self.shippingPrompt(item: item, policy: policy, locale: locale))
    }

    public static func shippingPrompt(item: GoldenItem, policy: TriagePolicy, locale: Locale) -> String {
        // The sort time stands in for the clock, as it did then: it decides which
        // apps were important at that hour, and the Received and Dates lines.
        SecondOpinionPrompt.prompt(
            for: item.notification, policy: policy, correspondentMatch: { _ in nil }, now: item.triagedAt, locale: locale
        )
    }
}

/// A variant of the prompt: text with placeholders for the shipping prompt's parts.
///
/// - `{{instructions}}`, `{{policy}}`, `{{notification}}`, `{{answer}}`: each part as shipped.
/// - `{{answer.Category}}`, `{{answer.Reason}}`, …: one answer line as shipped. A line
///   holding only a placeholder with nothing to show, such as `{{answer.Task}}` when
///   deadlines aren't asked for, is left out.
/// - `{{answer.count}}`: how many answer lines the variant asks for, as a word.
///
/// Lines at the top starting with `#` describe the variant and aren't sent. One
/// starting with `#-` instead leaves out every line of the prompt that starts with
/// what follows it, so a variant can drop part of the shipping instructions and still
/// follow them as they change; one that matches nothing is a mistake.
public struct PromptTemplate: Equatable, Sendable {
    public let name: String
    public let text: String
    public let description: String
    public let removals: [String]

    public static let shippingText = "{{instructions}}\n\n{{policy}}\n\n{{notification}}\n\n{{answer}}"

    /// The prompt exactly as the iPhone and Karui for Mac send it.
    public static let shipping = PromptTemplate(name: "shipping", text: shippingText, description: "The prompt as shipped.")

    public init(name: String, text: String, description: String, removals: [String] = []) {
        self.name = name
        self.text = text
        self.description = description
        self.removals = removals
    }

    /// A variant file: its name is the file's, its description the `#` lines at its top.
    public init(contentsOf url: URL) throws {
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var description: [String] = []
        var removals: [String] = []
        while let first = lines.first, first.hasPrefix("#") {
            if first.hasPrefix("#-") {
                removals.append(first.dropFirst(2).trimmingCharacters(in: .whitespaces))
            } else {
                description.append(first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            }
            lines.removeFirst()
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        self.init(
            name: url.deletingPathExtension().lastPathComponent, text: lines.joined(separator: "\n"),
            description: description.joined(separator: " "), removals: removals
        )
    }

    public func render(_ sections: PromptSections) throws -> String {
        var answerCount = 0
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            var rendered = line
            var hadPlaceholder = false
            for match in line.matches(of: /\{\{([A-Za-z.]+)\}\}/) {
                let key = String(match.output.1)
                if key == "answer.count" { continue }
                hadPlaceholder = true
                let value: String
                switch key {
                case "instructions": value = sections.instructions
                case "policy": value = sections.policy
                case "notification": value = sections.notification
                case "answer":
                    value = sections.answer
                    answerCount += sections.answerLines.count
                default:
                    guard key.hasPrefix("answer.") else { throw EvalError("\(name): no part called {{\(key)}}") }
                    let label = String(key.dropFirst("answer.".count))
                    let known = ["Category", "Confidence", "Reason", "Tags", "Task", "Due"]
                    guard known.contains(label) || sections.answerLines.contains(where: { $0.label == label }) else {
                        throw EvalError("\(name): no answer line called {{\(key)}}")
                    }
                    value = sections.answerLines.first { $0.label == label }?.line ?? ""
                    if !value.isEmpty { answerCount += 1 }
                }
                rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            // A line that was only a placeholder with nothing to show goes.
            if hadPlaceholder, rendered.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            lines.append(rendered)
        }
        var prompt = lines.joined(separator: "\n").replacingOccurrences(of: "{{answer.count}}", with: Self.word(answerCount))
        if !removals.isEmpty {
            var kept: [String] = []
            var matched = Set<String>()
            for line in prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let removal = removals.first(where: { trimmed.hasPrefix($0) }) {
                    matched.insert(removal)
                } else {
                    kept.append(line)
                }
            }
            if let missing = removals.first(where: { !matched.contains($0) }) {
                throw EvalError("\(name): no line of the prompt starts with “\(missing)”")
            }
            prompt = kept.joined(separator: "\n")
        }
        return prompt
    }

    /// A starting point for a variant: the shipping prompt's parts as placeholders, or
    /// with `expanded`, the instructions and answer lines written out to edit.
    public static func starter(sections: PromptSections, expanded: Bool) -> String {
        guard expanded else { return shippingText }
        let answer = ["Answer with exactly {{answer.count}} lines and nothing else:"]
            + sections.answerLines.map { "{{answer.\($0.label)}}" }
        return [sections.instructions, "{{policy}}", "{{notification}}", answer.joined(separator: "\n")].joined(separator: "\n\n")
    }

    static func word(_ number: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return number < words.count ? words[number] : String(number)
    }
}
