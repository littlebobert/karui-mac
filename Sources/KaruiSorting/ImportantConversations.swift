import Foundation

/// A conversation the person asked Karui to always alert about: a group chat, an
/// email thread, or a workplace channel, for a day, a week, or for good. Added from the prompt after making one of its
/// messages Important in History; listed under Settings → People.
public struct ImportantConversation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Every name the chat went by when it was added (`ConversationCooldown.keys`):
    /// its people and its name, so it still matches after a rename or a new member.
    public var keys: [String]
    /// The chat's name, as the notification showed it.
    public var name: String
    public var appName: String
    public var createdAt: Date
    /// Nil for always.
    public var expiresAt: Date?

    public init(
        keys: [String],
        name: String,
        appName: String,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.keys = keys
        self.name = name
        self.appName = appName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isActive(at now: Date) -> Bool {
        expiresAt.map { $0 > now } ?? true
    }

    public func lasting(_ duration: ImportantConversationDuration, from now: Date = .now) -> ImportantConversation {
        var conversation = self
        conversation.createdAt = now
        conversation.expiresAt = duration.length.map(now.addingTimeInterval)
        return conversation
    }
}

/// How long a conversation stays Important.
public enum ImportantConversationDuration: CaseIterable, Sendable {
    case day
    case week
    case always

    /// Nil for always.
    public var length: TimeInterval? {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .always: nil
        }
    }
}

/// Every message in an Important Conversation alerts, decided by rule ahead of the
/// model like a VIP's, and exempt from the conversation cooldown. A VIP in the chat
/// still gets the VIP rule first, so History keeps naming them.
public enum ImportantConversations {
    public static func result(
        for notification: NotificationInput,
        policy: TriagePolicy,
        now: Date = .now,
        locale: Locale = .current
    ) -> TriageResult? {
        guard let conversation = policy.importantConversation(for: notification, now: now) else { return nil }
        return TriageResult(
            category: .notifyNow,
            confidence: 1,
            reason: KaruiLocalization.formatted("Message in “%@”, which you marked Important.", conversation.name, locale: locale),
            engine: .deterministicRules,
            engineDetail: KaruiLocalization.string("Important conversations always alert.", locale: locale)
        )
    }

    /// The conversation's name: an email thread's subject without its "Re:", a
    /// workplace channel's title, otherwise a chat's subtitle, its people, or its title.
    public static func name(for notification: NotificationInput, recipients: String?) -> String {
        let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ConversationCooldown.kind(of: ImportantAppMatcher.canonicalKey(notification.source)) {
        case .email:
            let subject = ConversationCooldown.threadSubject(notification.subtitle)
            if !subject.isEmpty { return subject }
        case .workplace:
            if !title.isEmpty { return title }
        case .social:
            let post = notification.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !post.isEmpty { return post.count > 60 ? String(post.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : post }
        case .messaging:
            break
        }
        if let subtitle = notification.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            return subtitle
        }
        let people = (recipients ?? "")
            .split(whereSeparator: { [",", "\n", ";", "、"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if people.count >= 2 {
            return ListFormatter.localizedString(byJoining: people)
        }
        return title
    }
}
