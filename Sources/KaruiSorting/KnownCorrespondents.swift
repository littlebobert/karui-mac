import Foundation

/// A message from someone the person has written to alerts, even when the model
/// would file it as Neutral: the Saved Contacts rule, extended by Karui for Mac to
/// the apps where a name says nothing on its own, since the Mac knows who the
/// person actually corresponds with.
///
/// As with Saved Contacts, the model sorts first: Spam stays Spam, and a Neutral
/// only rises when the model also read it as written by a person or about the
/// user's own affairs. The same exception list applies, so taking someone off one
/// rule takes them off both.
public enum KnownCorrespondents {
    /// The correspondent a notification is from, as the notification shows them;
    /// nil when the rule is off, in quiet apps, in group chats, and for people the
    /// user took off the rule.
    /// `match` finds the correspondent in Karui for Mac's list.
    public static func name(
        for notification: NotificationInput,
        policy: TriagePolicy,
        match: (NotificationInput) -> String?
    ) -> String? {
        guard policy.alertKnownCorrespondents, !policy.isQuietApp(notification.source),
              !SavedContacts.isGroup(notification, policy: policy),
              let name = match(notification),
              !policy.isSavedContactException(name) else {
            return nil
        }
        return name
    }

    public static func applying(
        to result: TriageResult,
        for notification: NotificationInput,
        policy: TriagePolicy,
        match: (NotificationInput) -> String?,
        locale: Locale = .current
    ) -> TriageResult {
        guard result.category == .summary, (result.interest ?? 5) >= SavedContacts.minimumInterest,
              let name = name(for: notification, policy: policy, match: match) else {
            return result
        }
        var raised = TriageResult(
            category: .notifyNow,
            confidence: result.confidence,
            reason: KaruiLocalization.formatted("You’ve written to %@ before.", name, locale: locale),
            engine: result.engine,
            engineDetail: KaruiLocalization.string("People you’ve written to always alert.", locale: locale),
            interest: result.interest
        )
        raised.isModelFallback = result.isModelFallback
        raised.tags = result.tags
        raised.modelDuration = result.modelDuration
        raised.deadline = result.deadline
        return raised
    }
}
