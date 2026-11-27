import Foundation

/// What Karui asks Private Cloud Compute, and how it reads the answer: the same rules
/// as the on-device model, with the least of the person's policy those rules need.
/// The iPhone asks itself or through its Shortcut's Use Model step; Karui for Mac
/// through a Shortcut of its own.
public enum SecondOpinionPrompt {
    /// The prompt the Shortcut sends to Private Cloud Compute. The same rules as the
    /// on-device model, with the least of the user's policy that those rules need:
    /// the notification, the app, whether it's an important app right now (work apps
    /// already drop out off hours, so they're not named), the user's names, and their
    /// terms. Never VIP contact details or calendar events. A VIP's message is
    /// Important by rule and never gets this prompt; with deadline reminders on it may
    /// get `deadlinePrompt`, which asks only about the task and day.
    /// `correspondentMatch` finds the sender in Karui for Mac's list of people the
    /// person has written to.
    public static func prompt(
        for notification: NotificationInput,
        policy: TriagePolicy,
        correspondentMatch: (NotificationInput) -> String?,
        now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let isImportantApp = ImportantAppMatcher.matchingApp(
            for: notification.source,
            in: policy.importantApps(activeAt: now)
        ) != nil
        // With deadline reminders on, the cloud model is asked for the task and day
        // too, as the on-device model is.
        let extractsDeadline = policy.deadlineRemindersEnabled
        let received = notification.receivedAt ?? now
        // Only while the person is expecting something; otherwise the prompt is as it was.
        let expectedSection = ExpectedItems.promptSection(for: policy, now: now)
        let lineCount = 5 + (extractsDeadline ? 2 : 0) + (expectedSection == nil ? 0 : 1)
        return """
        \(TriageInstructions.text(reasonLanguageInstruction: TriageInstructions.reasonLanguageInstruction(locale: locale)))\(extractsDeadline ? "\n" + DeadlineExtraction.instructions : "")

        User policy:
        Important contacts: not provided. Karui has already checked them, so do not assume the Sender is one.
        User's names: \(termsText(policy.userNames))
        Urgent terms: \(termsText(policy.urgentKeywords))
        Summary terms: \(termsText(policy.summaryKeywords))
        Silence terms: \(termsText(policy.silenceKeywords))
        \(policy.prioritizeCalendarAndTravel
            ? "Calendar and travel: prioritize reminders about, and changes to, the user's own booked appointments, reservations, meetings, flights, and trains happening soon. A message that only mentions one of these events, like someone confirming they'll be there, is not a reminder or a change. Ads and news about travel are not the user's bookings."
            : "Calendar and travel: no special priority; judge these like any other notification.")
        \(policy.silencePromotions
            ? "Promotions: marketing, sales, and discount offers are Spam."
            : "Promotions: the user wants to see marketing, sales, and discount offers, so they are Neutral unless they match a silence term.")\(expectedSection.map { "\n" + $0 } ?? "")
        The user's calendar is not provided. Do not connect the notification to any event.

        Notification:
        \(NotificationPromptFormatter.format(notification, isImportantApp: isImportantApp, userNames: policy.commaSeparatedValues(from: policy.userNames), isKnownCorrespondent: KnownCorrespondents.name(for: notification, policy: policy, match: correspondentMatch) != nil, now: now))\(extractsDeadline ? "\n" + DeadlineExtraction.datesPromptLine(receivedAt: received) : "")

        Answer with exactly \(lineCountWords[lineCount] ?? "\(lineCount)") lines and nothing else:
        Category: Important, Neutral, or Spam\(expectedSection == nil ? "" : "\nExpected: the number of the expected item this notification clearly is, or None")
        Confidence: a number from 0.0 through 1.0
        Interest: a whole number from 1 through 5, rated as described above
        Reason: the reason, in at most 20 words
        Tags: three to five search tags of one to three words, specific to what the notification is about (not generic words like update or message, and preferably words not already in the notification: a synonym, its category, or its name in another language), comma separated, each in every one of these languages: \(SearchTags.languages(readLanguages: policy.readLanguages, locale: locale).joined(separator: ", "))\(extractsDeadline ? """

        Task: the task, or None
        Due: the dueDate as YYYY-MM-DD, or None
        """ : "")
        """
    }

    /// The prompt for a deadline check: only the deadline instructions, the
    /// notification, and the coming week's dates. Nothing about the user's policy, and
    /// no VIP contact details even for a VIP's message; the sender's name is in the
    /// notification as the app showed it.
    public static func deadlinePrompt(
        for notification: NotificationInput,
        policy: TriagePolicy,
        now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let received = notification.receivedAt ?? now
        return """
        \(DeadlineExtraction.deadlineOnlyInstructions(taskLanguage: KaruiLocalization.modelLanguageName(locale)))

        Notification:
        \(NotificationPromptFormatter.format(notification, isImportantApp: false, userNames: policy.commaSeparatedValues(from: policy.userNames), now: now))
        \(DeadlineExtraction.datesPromptLine(receivedAt: received))

        Answer with exactly three lines and nothing else:
        Reason: what the notification asks the user to do and by when, or that it asks nothing, in at most 20 words
        Task: the task, or None
        Due: the day as YYYY-MM-DD, or None
        """
    }

    private static let lineCountWords = [5: "five", 6: "six", 7: "seven", 8: "eight"]

    private static func termsText(_ terms: String) -> String {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "none" : trimmed
    }

    public struct Answer: Equatable, Sendable {
        public let category: TriageCategory
        public let confidence: Double
        public let reason: String
        /// What the notification asks of the user and by which day, as written; only
        /// asked for while deadline reminders are on.
        public var task: String?
        public var dueDate: String?
        /// Search tags, when the answer had a Tags line. See `SearchTags`.
        public var tags: [String]?
        /// The interest rating from 1 through 5, as the on-device model gives it, when
        /// the answer had one: what the Neutral Summary ranks by.
        public var interest: Int?
        /// The number of the expected item the answer says the notification is
        /// (`ExpectedItems`). Nil for none, or when the prompt listed none.
        public var expected: Int?

        public init(
            category: TriageCategory,
            confidence: Double,
            reason: String,
            task: String? = nil,
            dueDate: String? = nil,
            tags: [String]? = nil,
            interest: Int? = nil,
            expected: Int? = nil
        ) {
            self.category = category
            self.confidence = confidence
            self.reason = reason
            self.task = task
            self.dueDate = dueDate
            self.tags = tags
            self.interest = interest
            self.expected = expected
        }
    }

    /// The Task and Due lines of a deadline check's answer, as written. Nil when the
    /// answer has no Task line at all, which means it wasn't read as asked.
    public static func parseDeadline(answer: String) -> (task: String, dueDate: String)? {
        var task: String?
        var dueDate: String?
        for line in answer.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let value = labeledValue(in: line, labels: ["task", "タスク", "할 일", "aufgabe"]) {
                task = task ?? value
            } else if let value = labeledValue(in: line, labels: ["due", "due date", "duedate", "期限", "期日", "마감", "마감일", "fällig", "frist"]) {
                dueDate = dueDate ?? value
            }
        }
        guard let task else { return nil }
        return (task, dueDate ?? "")
    }

    /// Reads the cloud model's answer, forgiving of extra words, missing lines, or the
    /// category written in Japanese or Korean. Nil when no category can be found.
    public static func parse(answer: String) -> Answer? {
        // Sometimes the model answers in JSON instead of the lines asked for.
        if let answer = parseJSON(answer: answer) { return answer }
        let lines = answer
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var category: TriageCategory?
        var confidence: Double?
        var reason: String?
        var task: String?
        var dueDate: String?
        var tags: [String]?
        var interest: Int?
        var expected: Int?
        for line in lines {
            if let value = labeledValue(in: line, labels: ["category", "カテゴリ", "分類", "카테고리", "분류", "kategorie"]) {
                category = category ?? Self.category(in: value)
            } else if let value = labeledValue(in: line, labels: expectedLabels) {
                expected = expected ?? Self.expected(in: value)
            } else if let value = labeledValue(in: line, labels: ["confidence", "確信度", "信頼度", "확신도", "신뢰도", "sicherheit", "konfidenz"]) {
                confidence = confidence ?? Self.number(in: value)
            } else if let value = labeledValue(in: line, labels: interestLabels) {
                interest = interest ?? Self.interest(in: value)
            } else if let value = labeledValue(in: line, labels: ["reason", "理由", "이유", "grund", "begründung"]) {
                reason = reason ?? value
            } else if let value = labeledValue(in: line, labels: ["tags", "tag", "タグ", "태그", "schlagwörter"]) {
                tags = tags ?? SearchTags.cleaned(value.split(whereSeparator: { [",", "、", "，", ";", "/"].contains($0) }).map(String.init))
            } else if let value = labeledValue(in: line, labels: ["task", "タスク", "할 일", "aufgabe"]) {
                task = task ?? value
            } else if let value = labeledValue(in: line, labels: ["due", "due date", "duedate", "期限", "期日", "마감", "마감일", "fällig", "frist"]) {
                dueDate = dueDate ?? value
            }
        }
        // No labeled category line: the first category word anywhere decides.
        let resolvedCategory = category ?? Self.category(in: answer)
        guard let resolvedCategory else { return nil }
        // A line with words: never a lone brace or code fence from a stray JSON answer.
        let fallbackReason = lines.first {
            $0.contains(where: \.isLetter)
                && Self.category(in: $0) == nil && Self.number(in: $0) == nil
                && labeledValue(in: $0, labels: ["task", "タスク", "할 일", "aufgabe"]) == nil
                && labeledValue(in: $0, labels: ["tags", "tag", "タグ", "태그", "schlagwörter"]) == nil
                && labeledValue(in: $0, labels: interestLabels) == nil
                && labeledValue(in: $0, labels: expectedLabels) == nil
        } ?? ""
        let resolvedReason = String((reason ?? fallbackReason).prefix(200))
        return Answer(
            category: resolvedCategory,
            confidence: min(max(confidence ?? 0.7, 0), 1),
            reason: resolvedReason,
            task: task,
            dueDate: dueDate,
            tags: tags,
            interest: interest,
            expected: expected
        )
    }

    /// A JSON object anywhere in the answer, in or out of a code fence, with the same
    /// fields as the lines. Nil when there's no object or it names no category.
    private static func parseJSON(answer: String) -> Answer? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var fields: [String: Any] = [:]
        for (key, value) in object {
            fields[key.lowercased().filter(\.isLetter)] = value
        }
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let value = fields[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }
        guard let category = text("category", "カテゴリ", "分類", "카테고리", "분류").flatMap(Self.category(in:)) else {
            return nil
        }
        let confidence = (fields["confidence"] as? NSNumber)?.doubleValue
            ?? text("confidence").flatMap(Self.number(in:))
        let tagValues: [String]? = (fields["tags"] as? [Any])?.compactMap { $0 as? String }
            ?? text("tags").map { $0.split(whereSeparator: { [",", "、", "，", ";", "/"].contains($0) }).map(String.init) }
        return Answer(
            category: category,
            confidence: min(max(confidence.map { $0 > 1 ? $0 / 100 : $0 } ?? 0.7, 0), 1),
            reason: String((text("reason", "理由", "이유") ?? "").prefix(200)),
            task: text("task", "タスク"),
            dueDate: text("due", "duedate"),
            tags: tagValues.flatMap { SearchTags.cleaned($0) },
            interest: (fields["interest"] as? NSNumber).map { min(max($0.intValue, 1), 5) }
                ?? text("interest").flatMap(Self.interest(in:)),
            expected: (fields["expected"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
                ?? text("expected").flatMap(Self.expected(in:))
        )
    }

    private static func labeledValue(in line: String, labels: [String]) -> String? {
        let lowered = line.lowercased()
        for label in labels {
            for separator in [":", "："] {
                let prefix = label.lowercased() + separator
                if lowered.hasPrefix(prefix) {
                    // "**Category:** Important" leaves the closing asterisks on the value.
                    return String(line.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                }
            }
        }
        // "**Category:** Important" and "- Category: Important" from a chattier model.
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
        return stripped == line ? nil : labeledValue(in: stripped, labels: labels)
    }

    /// "Not important" and "unimportant" contain "important"; each is blanked before
    /// the search, so a Neutral verdict phrased as a negation isn't read as Important.
    private static let negatedCategoryWords = [
        "unimportant", "not important", "non-important", "isn't important", "isn’t important",
        "重要ではない", "重要でない", "重要ではありません", "重要じゃない", "重要度は低", "重要度が低",
        "중요하지 않", "중요하진 않",
        "unwichtig", "nicht wichtig",
    ]

    private static func category(in text: String) -> TriageCategory? {
        var lowered = text.lowercased()
        var wasNegated = false
        for negated in negatedCategoryWords where lowered.contains(negated) {
            wasNegated = true
            lowered = lowered.replacingOccurrences(of: negated, with: String(repeating: " ", count: negated.count))
        }
        let candidates: [(String, TriageCategory)] = [
            ("important", .notifyNow), ("重要", .notifyNow), ("중요", .notifyNow), ("wichtig", .notifyNow),
            ("neutral", .summary), ("中立", .summary), ("普通", .summary), ("보통", .summary),
            ("spam", .silence), ("スパム", .silence), ("迷惑", .silence), ("스팸", .silence),
        ]
        let found = candidates
            .compactMap { word, category in lowered.range(of: word).map { ($0.lowerBound, category) } }
            .min { $0.0 < $1.0 }?
            .1
        // "Not important" with no other category named is a Neutral verdict.
        return found ?? (wasNegated ? .summary : nil)
    }

    private static let interestLabels = ["interest", "関心度", "興味", "興味度", "관심도", "관심", "interesse"]

    private static let expectedLabels = ["expected", "expecting", "期待", "予期", "예상", "erwartet"]

    /// The item's number: "2", "2.", "Item 2". Nil for "None", "0", or no number.
    private static func expected(in text: String) -> Int? {
        guard let digits = text.firstMatch(of: /\d+/), let value = Int(digits.output), value > 0 else { return nil }
        return value
    }

    /// The first whole number in the value, kept to 1 through 5: "4", "4/5", "4 out of 5".
    private static func interest(in text: String) -> Int? {
        guard let digits = text.firstMatch(of: /\d+/), let value = Int(digits.output) else { return nil }
        return min(max(value, 1), 5)
    }

    private static func number(in text: String) -> Double? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: ".-"))
        guard let value = scanner.scanDouble() else { return nil }
        // "85%" or "85" mean 0.85.
        return value > 1 ? value / 100 : value
    }
}
