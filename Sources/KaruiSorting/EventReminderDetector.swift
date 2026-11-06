import Foundation

/// Finds reminders for the person's own events, so they alert even when a model reads
/// "Starts in 10 minutes" as a routine status. Private Cloud Compute never sees the
/// calendar, and called about half of these Neutral; the person graded every one
/// Important.
///
/// Two kinds count: a calendar app's own alert ("Today at 15:00", "Leave by 18:25 to
/// get to…"), and a mail app's calendar alert, which Spark titles "📅 Event" with a
/// body like "Starts in 10 minutes at 12:00". Invitations and replies to them aren't
/// reminders; the model sorts those.
public enum EventReminderDetector {
    /// Apps whose notifications are about the person's own calendar.
    static let calendarApps: Set<String> = ["calendar", "google calendar", "fantastical", "busycal", "timetree", "カレンダー", "캘린더", "kalender"]
        .reduce(into: []) { $0.insert(ImportantAppMatcher.canonicalKey($1)) }

    /// The title a mail app's calendar alert starts with.
    static let calendarEmoji = "📅"

    /// A time of day: "9:00", "18:25", "9:00 AM", "午後3:00".
    private static let clockTime = try! NSRegularExpression(pattern: #"(?<!\d)\d{1,2}[:：]\d{2}(?!\d)"#)

    /// When to leave, from Calendar's time-to-leave alerts.
    private static let leaveWords = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:leave now|leave by|to get to)(?!\p{L})|出発|출발|losfahren|aufbrechen"#,
        options: [.caseInsensitive]
    )

    /// Starts and wording of an invitation or someone's reply to one, which the model
    /// sorts: it may need the person's answer, but it isn't a reminder.
    private static let notReminderWords = try! NSRegularExpression(
        pattern: #"^(?:new )?invitation|invited you|accepted|declined|tentative|^招待|招待されました|承諾|辞退|^초대|수락|거절|^einladung|zugesagt|abgesagt"#,
        options: [.caseInsensitive]
    )

    /// "Starts in 10 minutes", "Starts Tomorrow at 9:00", and the like.
    private static let startsWords = try! NSRegularExpression(
        pattern: #"(?<!\p{L})starts?(?!\p{L})|開始|시작|beginnt"#,
        options: [.caseInsensitive]
    )

    /// The event's name when the notification reminds the person of one of their own
    /// events; nil otherwise.
    public static func eventName(in notification: NotificationInput) -> String? {
        let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = notification.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !matches(notReminderWords, body), !matches(notReminderWords, title) else { return nil }
        if title.hasPrefix(calendarEmoji) {
            let name = String(title.dropFirst(calendarEmoji.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, matches(startsWords, body) || matches(clockTime, body) else { return nil }
            return name
        }
        guard calendarApps.contains(ImportantAppMatcher.canonicalKey(notification.source)) else { return nil }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        guard matches(clockTime, firstLine) || matches(leaveWords, body) || matches(startsWords, firstLine) else { return nil }
        return title
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
