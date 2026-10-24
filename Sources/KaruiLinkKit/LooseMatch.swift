import Foundation

/// The same notification as each device saw it, when the fingerprints differ: one
/// app fills a field the other leaves empty (Spark for Mac says "No subject" where
/// Spark for iPhone says nothing), or Slack words a post or a direct message
/// differently on each. The Mac joins the iPhone's verdict to its own copy by this,
/// and the iPhone answers the Mac's request to sort a notification with the copy it
/// already filed.
/// Callers check the app and that the two arrived within `window`.
public enum LooseMatch {
    public static let window: TimeInterval = 15 * 60

    public struct Fields: Sendable {
        public var title: String?
        public var subtitle: String?
        public var body: String?

        public init(title: String?, subtitle: String?, body: String?) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
        }
    }

    /// Either way round. The same sender and text, the iPhone sending the subject
    /// and body as one text, subject first; or, in Slack, the same post or direct
    /// message.
    public static func sameNotification(app: String, _ one: Fields, _ other: Fields) -> Bool {
        if app == KnownApp.slack.rawValue,
           slackPost(one, other) || slackPost(other, one) || slackDirectMessage(one, other) || slackDirectMessage(other, one) {
            return true
        }
        let title = NotificationFingerprint.normalize(one.title)
        guard !title.isEmpty, title == NotificationFingerprint.normalize(other.title) else { return false }
        let body = NotificationFingerprint.normalize(one.body), otherBody = NotificationFingerprint.normalize(other.body)
        guard !body.isEmpty, !otherBody.isEmpty else { return false }
        if body == otherBody || body.hasSuffix(otherBody) || otherBody.hasSuffix(body) { return true }
        return sameTextAfterSubject(one, body: body, other, otherBody: otherBody)
    }

    /// Shorter than this, two texts from the same sender that start alike, as "Hi"
    /// and "Hi there", aren't taken for one.
    static let sharedStartLength = 20

    /// Spark: the iPhone sends the subject, then the email's first line; the Mac keeps
    /// the subject apart and a longer preview of the text. So: the same subject, as a
    /// subtitle or at the start of the text, and after it the same text as far as
    /// the shorter goes.
    private static func sameTextAfterSubject(_ one: Fields, body: String, _ other: Fields, otherBody: String) -> Bool {
        let subject = NotificationFingerprint.normalize(one.subtitle)
        let otherSubject = NotificationFingerprint.normalize(other.subtitle)
        func afterSubject(_ text: String, _ subject: String) -> Substring? {
            guard !subject.isEmpty else { return Substring(text) }
            guard text.hasPrefix(subject) else { return nil }
            return text.dropFirst(subject.count).drop { $0 == " " }
        }
        let texts: (Substring?, Substring?)
        switch (subject.isEmpty, otherSubject.isEmpty) {
        case (false, false):
            guard subject == otherSubject else { return false }
            texts = (afterSubject(body, subject) ?? Substring(body), afterSubject(otherBody, subject) ?? Substring(otherBody))
        case (false, true): texts = (afterSubject(body, subject) ?? Substring(body), afterSubject(otherBody, subject))
        case (true, false): texts = (afterSubject(body, otherSubject), afterSubject(otherBody, otherSubject) ?? Substring(otherBody))
        case (true, true): texts = (Substring(body), Substring(otherBody))
        }
        guard let text = texts.0.map(trimmingEllipsis), let otherText = texts.1.map(trimmingEllipsis) else { return false }
        let length = min(text.count, otherText.count)
        return length >= sharedStartLength && text.prefix(length) == otherText.prefix(length)
    }

    /// A preview cut short may end in "…".
    private static func trimmingEllipsis(_ text: Substring) -> Substring {
        var text = text
        while let last = text.last, last == "…" || last == "." || last == " " { text = text.dropLast() }
        return text
    }

    /// Slack shapes a post's notification differently on each device: the iPhone's
    /// is titled by the sender, with "In #channel" (a thread reply) or "To channel"
    /// (a post in the channel) as its subtitle and as the first line of the text it
    /// sends; the Mac's is titled by the workspace, with the channel as its subtitle
    /// and, from a person, "sender: " before the text. So: the same channel, and the
    /// same text as far as both go, each cut short at its own length.
    public static func slackPost(_ phone: Fields, _ mac: Fields) -> Bool {
        let phoneSubtitle = NotificationFingerprint.normalize(phone.subtitle)
        guard let prefix = ["in #", "to #", "to "].first(where: phoneSubtitle.hasPrefix) else { return false }
        let channel = phoneSubtitle.dropFirst(prefix.count)
        var macChannel = Substring(NotificationFingerprint.normalize(mac.subtitle))
        if macChannel.hasPrefix("#") { macChannel = macChannel.dropFirst() }
        guard !channel.isEmpty, channel == macChannel else { return false }
        var phoneText = Substring(NotificationFingerprint.normalize(phone.body))
        if phoneText.hasPrefix(phoneSubtitle) {
            phoneText = phoneText.dropFirst(phoneSubtitle.count).drop { $0 == " " }
        }
        return sameSlackText(phoneText, macBody: mac.body)
    }

    /// A Slack direct message: the iPhone's is titled by the sender, with no
    /// subtitle; the Mac's is titled by the workspace, with the sender as its
    /// subtitle. So: the same sender, and the same text as far as both go.
    public static func slackDirectMessage(_ phone: Fields, _ mac: Fields) -> Bool {
        guard NotificationFingerprint.normalize(phone.subtitle).isEmpty else { return false }
        let sender = NotificationFingerprint.normalize(phone.title)
        guard !sender.isEmpty, sender == NotificationFingerprint.normalize(mac.subtitle) else { return false }
        return sameSlackText(Substring(NotificationFingerprint.normalize(phone.body)), macBody: mac.body)
    }

    /// The iPhone's text against the Mac's, each cut short at its own length. A bot's
    /// post has no "sender: " before it, and its own text may hold ": ", as in "Tag:
    /// release": so the Mac's text as it is, or after the first ": ".
    private static func sameSlackText(_ phoneText: Substring, macBody: String?) -> Bool {
        let macText = Substring(NotificationFingerprint.normalize(macBody))
        var candidates = [macText]
        if let colon = macText.range(of: ": ") { candidates.append(macText[colon.upperBound...]) }
        return candidates.contains { text in
            let length = min(phoneText.count, text.count, 80)
            return length > 0 && phoneText.prefix(length) == text.prefix(length)
        }
    }
}
