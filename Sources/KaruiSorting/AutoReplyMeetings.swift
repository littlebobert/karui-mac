import Foundation

/// A calendar whose events turn Auto Reply on. The title and source are kept so the
/// calendar is still recognized if its identifier changes after a resync.
public struct AutoReplyCalendar: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var sourceTitle: String

    public init(
        id: String,
        title: String,
        sourceTitle: String
    ) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }

    public func matches(id: String, title: String, sourceTitle: String) -> Bool {
        self.id == id || (self.title == title && self.sourceTitle == sourceTitle)
    }
}

/// Turn On During Meetings: Auto Reply turns itself on during events on the chosen
/// calendars and off when they end. Nothing runs in the background; the Shortcut asks
/// whether a meeting is under way each time a notification arrives.
public struct AutoReplyMeetingRule: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var calendars: [AutoReplyCalendar] = []
    public var message: AutoReplyMessage = .meeting
    /// Set when Auto Reply is turned off by hand during a meeting: the rule stays out of
    /// the way until this date, the end of that meeting.
    public var skippedUntil: Date?

    public init() {}

    public func includes(calendarID: String, title: String, sourceTitle: String) -> Bool {
        calendars.contains { $0.matches(id: calendarID, title: title, sourceTitle: sourceTitle) }
    }

    public func isSkipped(at now: Date) -> Bool {
        guard let skippedUntil else { return false }
        return now < skippedUntil
    }

    /// The titles of the chosen calendars, for settings.
    public func calendarsDescription(locale: Locale = .current) -> String? {
        let titles = calendars.map(\.title)
        guard !titles.isEmpty else { return nil }
        return titles.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, calendars, message, skippedUntil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        calendars = (try? container.decodeIfPresent([AutoReplyCalendar].self, forKey: .calendars)) ?? []
        message = try container.decodeIfPresent(AutoReplyMessage.self, forKey: .message) ?? .meeting
        skippedUntil = try container.decodeIfPresent(Date.self, forKey: .skippedUntil)
    }
}

/// A calendar event, as much of it as the rule needs.
public struct MeetingEvent: Equatable, Sendable {
    public var title: String?
    public var startDate: Date
    public var endDate: Date
    public var isAllDay = false
    /// The person declined the invitation.
    public var isDeclined = false
    /// Marked free rather than busy, like a reminder-style event or a holiday.
    public var isFree = false
    public var calendarTitle: String

    public init(
        title: String? = nil,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        isDeclined: Bool = false,
        isFree: Bool = false,
        calendarTitle: String
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
        self.isFree = isFree
        self.calendarTitle = calendarTitle
    }

    /// A meeting, as opposed to a day marked on the calendar.
    public var isMeeting: Bool { !isAllDay && !isDeclined && !isFree && startDate < endDate }
}

/// The meeting under way, and when the run of back-to-back meetings it belongs to
/// began, so someone who messages across two meetings gets one reply.
public struct MeetingSession: Equatable, Sendable {
    public var title: String?
    public var calendarTitle: String
    /// When the run began.
    public var startDate: Date
    /// When the current meeting ends.
    public var endDate: Date

    public init(
        title: String? = nil,
        calendarTitle: String,
        startDate: Date,
        endDate: Date
    ) {
        self.title = title
        self.calendarTitle = calendarTitle
        self.startDate = startDate
        self.endDate = endDate
    }

    /// The session at `now`, or nil when no meeting is under way. Meetings that touch
    /// or overlap the current one extend the run backwards.
    public static func current(in events: [MeetingEvent], now: Date) -> MeetingSession? {
        let meetings = events.filter(\.isMeeting)
        let underWay = meetings.filter { $0.startDate <= now && now < $0.endDate }
        // The one that started last is the most specific: a standup inside a workshop.
        guard let latest = underWay.max(by: { $0.startDate < $1.startDate }) else { return nil }
        var runStart = underWay.map(\.startDate).min() ?? latest.startDate
        var extended = true
        while extended {
            extended = false
            for meeting in meetings where meeting.startDate < runStart && meeting.endDate >= runStart {
                runStart = meeting.startDate
                extended = true
            }
        }
        return MeetingSession(
            title: latest.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            calendarTitle: latest.calendarTitle,
            startDate: runStart,
            endDate: latest.endDate
        )
    }

    /// The meeting's title, or its calendar's when it has none.
    public var displayTitle: String { title ?? calendarTitle }
}

/// Why Auto Reply is on right now.
public enum AutoReplyActivation: Equatable, Sendable {
    /// Turned on by hand, until this date.
    case manual(until: Date)
    case meeting(MeetingSession)

    public var endDate: Date {
        switch self {
        case .manual(let until): until
        case .meeting(let session): session.endDate
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
