import Foundation

/// Something a notification asks the person to do by a certain day, as the on-device
/// model read it.
public struct ExtractedDeadline: Equatable, Sendable {
    public let task: String
    /// The start of the day it is due.
    public let dueDay: Date

    public init(
        task: String,
        dueDay: Date
    ) {
        self.task = task
        self.dueDay = dueDay
    }
}

/// Turns the model's two extra answers into a deadline, or nothing. The model is
/// small, so its answers are checked rather than trusted: a task with no usable day,
/// or a day that has already passed, is dropped.
public enum DeadlineExtraction {
    public static let maximumTaskLength = 80
    /// A deadline further out than this is more likely a misread year than a task.
    public static let maximumDaysAhead = 366

    /// A Slack message mentioning the user, "イベントで使いたく、アダプターを借ります
    /// 明日返します", made a reminder for the user to return what the sender borrowed:
    /// Japanese often leaves out who acts, and the mention reads like a request.
    static let senderPromises = """
        Neither does a promise the sender makes about their own action, such as "I'll return it tomorrow" or "I'll send the slides Friday": that is the sender's task, even when the message mentions the user. Japanese often leaves out who acts; a sentence like "明日返します" or "金曜に送ります" from the sender is the sender's own promise.
        """

    /// Added to the model's instructions only while deadline reminders are on, so
    /// everyone else's notifications are sorted exactly as before.
    public static let instructions = """
        Also look for a deadline: something the notification asks the user to do by a certain day.
        task: what the user must do, at most 8 words, such as "Pay invoice #2041". Leave it empty when nothing is asked of the user by a certain day.
        dueDate: that day as YYYY-MM-DD, taken from the Dates line, only when the notification itself names the day: a date, a weekday, "tomorrow", "end of the month". Leave it empty when there is no task or no day is named. Never guess a day from words like "soon", "later", or "before I leave".
        Only a request made to the user counts. A sale, offer, or promotion that ends on a day is not a task, and neither is an event the user merely attends. Someone describing their own plans or what they are waiting for asks nothing of the user. \(senderPromises) Leave both empty for all of these.
        Write the task in the same language as the reason.
        """

    /// For Private Cloud Compute, asked only about the deadline: a notification that
    /// the rules sorted (a VIP's message), or one the on-device model sorted and that
    /// names a day. The reason comes first so the model works out what is asked and
    /// of whom before it writes a task.
    public static func deadlineOnlyInstructions(taskLanguage: String) -> String {
        """
        Look for a deadline in one notification: something it asks the user to do by a certain day.
        Reason: first, in at most 20 words, what the notification asks the user to do, if anything, and the day it names, if any. The notification was sent to the user; someone describing their own plans or what they are waiting for asks nothing of the user. \(senderPromises)
        Task: what the user must do, at most 8 words, such as "Pay invoice #2041". None when nothing is asked of the user by a certain day.
        Due: that day as YYYY-MM-DD, taken from the Dates line, only when the notification itself names the day: a date, a weekday, "tomorrow", "end of the month". None when there is no task or no day is named. Never guess a day from words like "soon", "later", or "before I leave".
        Only a request made to the user counts. A sale, offer, or promotion that ends on a day is not a task, and neither is an event the user merely attends. Answer None for both when in doubt: a missed reminder costs less than a wrong one.
        Write the task in \(taskLanguage).
        """
    }

    /// Whether the text names a day at all. Cheap, and it saves a Private Cloud
    /// Compute request, which Apple limits, for the many messages that don't. "By",
    /// "before", and "until" are common in other senses ("before I leave", "made by"),
    /// so they count only with a day named soon after; "due" and "deadline" count on
    /// their own, as do the Japanese and Korean words.
    public static func mentionsADay(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let strongCues = ["due", "deadline", "まで", "締め切り", "締切", "期限", "까지", "마감", "기한"]
        if strongCues.contains(where: lowered.contains) { return true }
        for cue in ["by ", "before ", "until "] {
            var search = lowered.startIndex
            while let range = lowered.range(of: cue, range: search..<lowered.endIndex) {
                let following = lowered[range.upperBound...].prefix(dayWordWindow)
                if dayWords.contains(where: following.contains) || following.contains(where: \.isNumber) { return true }
                search = range.upperBound
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return false
        }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// How far after "by", "before", or "until" a day may be named: "by the end of next week".
    private static let dayWordWindow = 28
    private static let dayWords = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon ", "tue", "wed ", "thu", "fri ", "sat ", "sun ",
        "january", "february", "march", "april", "may ", "june", "july", "august", "september", "october", "november", "december",
        "jan ", "feb ", "mar ", "apr ", "jun ", "jul ", "aug ", "sep ", "oct ", "nov ", "dec ",
        "today", "tomorrow", "tonight", "weekend", "end of", "next week", "next month", "noon", "midnight", "eod", "eow",
    ]

    /// The model has no calendar, so "by Friday" needs the days spelled out.
    public static func datesPromptLine(receivedAt: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE yyyy-MM-dd"
        let days = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: receivedAt) }.map(formatter.string)
        guard let today = days.first else { return "" }
        return "Dates: today is \(today); the days after it are \(days.dropFirst().joined(separator: ", "))."
    }

    public static func deadline(
        task: String,
        dueDate: String,
        receivedAt: Date,
        calendar: Calendar = .current
    ) -> ExtractedDeadline? {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !emptyAnswers.contains(task.lowercased()) else { return nil }
        guard let match = dueDate.firstMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let dueDay = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              // 2026-02-31 rolls over into March; that is a misread, not a date.
              calendar.component(.month, from: dueDay) == month else {
            return nil
        }
        let receivedDay = calendar.startOfDay(for: receivedAt)
        guard dueDay >= receivedDay,
              let latest = calendar.date(byAdding: .day, value: maximumDaysAhead, to: receivedDay),
              dueDay <= latest else {
            return nil
        }
        return ExtractedDeadline(task: String(task.prefix(maximumTaskLength)), dueDay: calendar.startOfDay(for: dueDay))
    }

    /// What the model writes when told to leave a field empty and it can't.
    private static let emptyAnswers: Set<String> = ["none", "n/a", "na", "null", "nil", "empty", "-", "なし", "없음"]
}
