import Foundation

/// A one-to-one message or missed call from someone saved in Contacts alerts, even
/// when the model would file it as Neutral.
///
/// Karui doesn't read Contacts for this. In Messages, WhatsApp, Phone, and FaceTime a
/// notification names its sender only when they're saved; anyone else shows as a
/// number. Other apps show a profile name for everyone, so there a name says nothing.
///
/// It can't be a rule ahead of the model, because businesses that text from a name
/// instead of a number ("Amazon") look the same. So the model sorts first: Spam stays
/// Spam, and a Neutral only rises when the model also read it as written by a person
/// or about the user's own affairs.
public enum SavedContacts {
    /// The lowest interest the model can give a Neutral for it to rise. 4 and 5 are
    /// the user's own affairs and a person writing to them; 3 and below are group
    /// chatter, routine status, and marketing.
    public static let minimumInterest = 4

    /// The saved contact a notification is from, as far as the notification shows.
    /// Nil in other apps, in group chats, for numbers, and for people the user took
    /// off this rule.
    public static func name(for notification: NotificationInput, policy: TriagePolicy) -> String? {
        guard policy.alertSavedContacts, !policy.isQuietApp(notification.source) else { return nil }
        let candidate: String?
        if CallBackApp(source: notification.source) != nil {
            // Missed calls carry no sender and put the caller in the title.
            candidate = notification.sender ?? (isCallPhrase(notification.title) ? nil : notification.title)
        } else {
            guard let app = SourceAppRouter.route(for: notification.source)?.appName,
                  app == "Messages" || app == "WhatsApp",
                  !isGroup(notification, policy: policy) else {
                return nil
            }
            candidate = notification.sender
        }
        guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), isSavedName(name),
              !policy.isSavedContactException(name) else {
            return nil
        }
        return name
    }

    public static func applying(
        to result: TriageResult,
        for notification: NotificationInput,
        policy: TriagePolicy,
        locale: Locale = .current
    ) -> TriageResult {
        // No interest means the rules stood in for the model, which can't tell a
        // person from a receipt; the name is the better guide then.
        guard result.category == .summary, (result.interest ?? 5) >= minimumInterest,
              let name = name(for: notification, policy: policy) else {
            return result
        }
        var raised = TriageResult(
            category: .notifyNow,
            confidence: result.confidence,
            reason: KaruiLocalization.formatted("%@ is saved in your contacts.", name, locale: locale),
            engine: result.engine,
            engineDetail: KaruiLocalization.string("Saved contacts always alert.", locale: locale),
            interest: result.interest
        )
        raised.isModelFallback = result.isModelFallback
        raised.tags = result.tags
        raised.modelDuration = result.modelDuration
        raised.deadline = result.deadline
        return raised
    }

    /// A name, as opposed to a number, an address, iOS's guess at who an unsaved
    /// number is ("Maybe: Sam"), WhatsApp's profile name for an unsaved number
    /// ("~Sam"), or a carrier's spam label.
    public static func isSavedName(_ sender: String) -> Bool {
        guard !sender.isEmpty, sender.rangeOfCharacter(from: .letters) != nil,
              !sender.contains("~"), !sender.contains("@"),
              sender.filter(\.isNumber).count < 5 else {
            return false
        }
        let lowered = sender.lowercased()
        let notNames = ["maybe:", "maybe ", "もしかして", "아마", "unknown", "no caller id", "spam", "scam", "fraud", "非通知", "不明", "迷惑", "발신자 표시 없음", "스팸"]
        return !notNames.contains(where: lowered.contains)
    }

    /// Messages lists a group's other members in Recipients and its name in the
    /// subtitle. One recipient who isn't the user is a third person; with no names
    /// saved for the user, a lone recipient is taken to be them.
    public static func isGroup(_ notification: NotificationInput, policy: TriagePolicy) -> Bool {
        if notification.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if ConversationCooldown.isGroup(recipients: notification.recipients) { return true }
        let userNames = policy.commaSeparatedValues(from: policy.userNames)
        guard !userNames.isEmpty,
              let recipient = notification.recipients?.trimmingCharacters(in: .whitespacesAndNewlines),
              !recipient.isEmpty else {
            return false
        }
        return !userNames.contains { ImportantPersonMatcher.namesMatch($0, recipient) }
    }

    /// A missed call's title when it describes the call instead of naming the caller.
    private static func isCallPhrase(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["missed", "call", "facetime", "不在着信", "着信", "부재중", "전화"].contains(where: lowered.contains)
    }
}
