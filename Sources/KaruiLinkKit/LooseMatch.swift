import Foundation

/// The same notification as each device saw it, when the fingerprints differ: one
/// app fills a field the other leaves empty (Spark for Mac says "No subject" where
/// Spark for iPhone says nothing), or Slack words a thread reply differently on
/// each. The Mac joins the iPhone's verdict to its own copy by this, and the iPhone
/// answers the Mac's request to sort a notification with the copy it already filed.
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
    /// and body as one text, subject first; or, in Slack, the same thread reply.
    public static func sameNotification(app: String, _ one: Fields, _ other: Fields) -> Bool {
        if app == KnownApp.slack.rawValue, slackThreadReply(one, other) || slackThreadReply(other, one) {
            return true
        }
        let title = NotificationFingerprint.normalize(one.title)
        guard !title.isEmpty, title == NotificationFingerprint.normalize(other.title) else { return false }
        let body = NotificationFingerprint.normalize(one.body), otherBody = NotificationFingerprint.normalize(other.body)
        guard !body.isEmpty, !otherBody.isEmpty else { return false }
        return body == otherBody || body.hasSuffix(otherBody) || otherBody.hasSuffix(body)
    }

    /// Slack shapes a thread reply's notification differently on each device: the
    /// iPhone's is titled by the sender, with "In #channel" as its subtitle and as
    /// the first line of the text it sends; the Mac's is titled by the workspace,
    /// with the channel as its subtitle and "sender: " before the text. So: the same
    /// channel, and the same text as far as both go, each cut short at its own length.
    public static func slackThreadReply(_ phone: Fields, _ mac: Fields) -> Bool {
        let phoneSubtitle = NotificationFingerprint.normalize(phone.subtitle)
        guard phoneSubtitle.hasPrefix("in #") else { return false }
        let channel = phoneSubtitle.dropFirst("in #".count)
        var macChannel = Substring(NotificationFingerprint.normalize(mac.subtitle))
        if macChannel.hasPrefix("#") { macChannel = macChannel.dropFirst() }
        guard !channel.isEmpty, channel == macChannel else { return false }
        var phoneText = Substring(NotificationFingerprint.normalize(phone.body))
        if phoneText.hasPrefix(phoneSubtitle) {
            phoneText = phoneText.dropFirst(phoneSubtitle.count).drop { $0 == " " }
        }
        var macText = Substring(NotificationFingerprint.normalize(mac.body))
        if let colon = macText.range(of: ": ") { macText = macText[colon.upperBound...] }
        let length = min(phoneText.count, macText.count, 80)
        guard length > 0 else { return false }
        return phoneText.prefix(length) == macText.prefix(length)
    }
}
