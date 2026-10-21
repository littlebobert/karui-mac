import Foundation

/// After Karui alerts about a conversation, further alerts from it wait out a cooldown
/// and are saved as Neutral instead, so a busy group chat alerts once rather than for
/// every message. The first seconds are left to Combine Rapid Messages, and anything
/// that looks urgent still alerts.
public enum ConversationCooldown {
    public static let duration: TimeInterval = 10 * 60
    /// Alerts this soon after the first one can still update its combined notification:
    /// Combine Rapid Messages' longest wait, which the app's `RapidMessageBatcher` takes from here.
    public static let grace: TimeInterval = 15

    /// The conversation a notification belongs to, within its app: the people in a
    /// group (stable when the group is renamed), otherwise the chat's name from the
    /// subtitle, otherwise the title, which messaging apps set to the chat or person,
    /// otherwise the sender.
    public static func key(for notification: NotificationInput, recipients: String?) -> String? {
        keys(for: notification, recipients: recipients).first
    }

    /// Every name the conversation goes by, best first: a group listed by its people
    /// and named in the subtitle has both, so Important Conversations still match it
    /// after a rename or a change of members. The title and the sender only stand in
    /// when there is nothing better; in a named group the title is the sender, and
    /// keying on it would match that person's own chat too.
    public static func keys(for notification: NotificationInput, recipients: String?) -> [String] {
        let app = ImportantAppMatcher.canonicalKey(notification.source)
        guard !app.isEmpty else { return [] }
        var keys: [String] = []
        switch kind(of: app) {
        case .email:
            // The thread, by its subject; the title is the sender.
            let subject = normalized(threadSubject(notification.subtitle))
            if !subject.isEmpty { return ["\(app)|thread|\(subject)"] }
        case .workplace:
            // The channel or group is the title, the workspace the subtitle; a direct
            // message's title is the person. Slack names the channel for a thread
            // reply too, so a thread goes by its channel.
            let title = normalized(notification.title)
            if !title.isEmpty { return ["\(app)|chat|\(title)"] }
        case .social:
            // The title says what happened ("Liked by Colin"); the body is the post,
            // which is the thread. Without a post there is no thread: the title would
            // only gather everything one person did.
            let post = postKey(notification.body)
            return post.isEmpty ? [] : ["\(app)|post|\(post)"]
        case .messaging:
            let people = people(in: recipients)
            if people.count >= 2 {
                keys.append("\(app)|group|" + people.sorted().joined(separator: ","))
            }
            let chat = normalized(notification.subtitle ?? "")
            if !chat.isEmpty { keys.append("\(app)|chat|\(chat)") }
            if !keys.isEmpty { return keys }
        }
        // The title names the chat or the person; the same key as a subtitle's name,
        // since an app can put a group's name in either from one notification to the next.
        let title = normalized(notification.title)
        if !title.isEmpty { return ["\(app)|chat|\(title)"] }
        let sender = normalized(notification.sender ?? "")
        return sender.isEmpty ? [] : ["\(app)|sender|\(sender)"]
    }

    /// A message to the user alone in a workplace app, as its notification shows one:
    /// the title is the sender's own name, where a channel or a thread reply names the
    /// channel. Only meaningful where the sender is given apart from the title.
    public static func looksLikeDirectMessage(_ notification: NotificationInput) -> Bool {
        guard kind(of: ImportantAppMatcher.canonicalKey(notification.source)) == .workplace else { return false }
        let sender = normalized(notification.sender ?? "")
        return !sender.isEmpty && normalized(notification.title) == sender
    }

    /// A conversation with more in it than one person writing to you, as far as the
    /// notification shows: a group with two or more recipients or a name in the
    /// subtitle, an email thread with a subject, or a workplace channel, whose title
    /// isn't the sender's own name.
    public static func isGroupChat(_ notification: NotificationInput, recipients: String?) -> Bool {
        switch kind(of: ImportantAppMatcher.canonicalKey(notification.source)) {
        case .email:
            return !threadSubject(notification.subtitle).isEmpty
        case .workplace:
            let title = normalized(notification.title)
            return !title.isEmpty && title != normalized(notification.sender ?? "")
        case .social:
            return !postKey(notification.body).isEmpty
        case .messaging:
            return isGroup(recipients: recipients)
                || notification.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// How an app's notifications name a conversation.
    public enum Kind {
        /// Messaging apps, and anything else: a group by its people or the subtitle.
        case messaging
        /// The thread by its subject.
        case email
        /// The channel by the title.
        case workplace
        /// The post by its text; the title only says what happened to it.
        case social
    }

    public static func kind(of canonicalApp: String) -> Kind {
        if emailApps.contains(canonicalApp) { return .email }
        if workplaceApps.contains(canonicalApp) { return .workplace }
        if socialApps.contains(canonicalApp) { return .social }
        return .messaging
    }

    /// By `ImportantAppMatcher.canonicalKey`, which folds localized names.
    public static let emailApps: Set<String> = ["mail", "gmail", "outlook", "spark"]
    public static let workplaceApps: Set<String> = ["slack", "microsoft teams", "discord", "chatwork"]
    public static let socialApps: Set<String> = ["x"]

    /// A post's opening, enough to tell posts apart, folded for matching.
    public static let postKeyLength = 80
    public static func postKey(_ body: String) -> String {
        String(normalized(body.replacingOccurrences(of: "\n", with: " ")).prefix(postKeyLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// An email thread's subject, without the reply and forward prefixes that vary
    /// along it: "Re: Re: Q3 budget" and "Fwd: Q3 budget" are one thread.
    public static func threadSubject(_ subject: String?) -> String {
        var subject = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = try! NSRegularExpression(
            pattern: "^(re|fw|fwd|aw|sv|tr|wg|回复|答复|返信|転送|답장|전달)(\\s*\\[\\d+\\])?\\s*[:：]\\s*",
            options: [.caseInsensitive]
        )
        while let match = prefix.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range, in: subject) {
            subject = String(subject[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return subject
    }

    /// A group chat, as far as the notification says: two or more recipients. Apps that
    /// don't list recipients look like one-to-one chats.
    public static func isGroup(recipients: String?) -> Bool {
        people(in: recipients).count >= 2
    }

    /// A VIP writing to you directly, codes, urgent terms, @mentions, time-sensitive
    /// notifications, and a third message from one person always alert.
    public static func isExempt(
        _ notification: NotificationInput,
        policy: TriagePolicy,
        isRepeated: Bool,
        isFromVIP: Bool = false,
        recipients: String? = nil
    ) -> Bool {
        if isFromVIP, !isGroup(recipients: recipients) { return true }
        if isRepeated || notification.isTimeSensitive == true { return true }
        if OneTimeCodeDetector.code(in: notification) != nil { return true }
        let text = [notification.title, notification.body, notification.translatedText]
            .compactMap { $0 }
            .joined(separator: "\n")
        if RuleBasedClassifier.firstMatch(in: text, terms: policy.terms(from: policy.urgentKeywords)) != nil {
            return true
        }
        return UserMentionDetector.mentionedName(
            in: notification,
            userNames: policy.commaSeparatedValues(from: policy.userNames)
        ) != nil
    }

    /// Whether an alert now should be held, given when this conversation's cooldown began.
    public static func shouldHold(since start: Date?, now: Date = .now) -> Bool {
        guard let start else { return false }
        let elapsed = now.timeIntervalSince(start)
        return elapsed >= grace && elapsed < duration
    }

    /// Neutral, saying why, and keeping the rest of the decision for History and the
    /// daily summary.
    public static func heldResult(_ result: TriageResult, locale: Locale = .current) -> TriageResult {
        var held = TriageResult(
            category: .summary,
            confidence: result.confidence,
            reason: KaruiLocalization.formatted(
                "Karui already alerted you about this conversation in the last %lld minutes.",
                Int64(duration / 60),
                locale: locale
            ),
            engine: result.engine,
            engineDetail: KaruiLocalization.string("Held by the conversation cooldown.", locale: locale),
            resolvedVIPIdentityID: result.resolvedVIPIdentityID,
            resolvedVIPDisplayName: result.resolvedVIPDisplayName,
            interest: result.interest
        )
        held.modelDuration = result.modelDuration
        held.tags = result.tags
        return held
    }

    private static func people(in recipients: String?) -> Set<String> {
        Set(
            (recipients ?? "")
                .split(whereSeparator: { [",", "\n", ";", "、"].contains($0) })
                .map(normalized)
                .filter { !$0.isEmpty }
        )
    }

    private static func normalized(_ value: some StringProtocol) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
