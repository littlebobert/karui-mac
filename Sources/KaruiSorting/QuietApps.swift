import Foundation

/// Apps where only VIPs, codes, urgent terms, and @mentions alert, for apps full of
/// spam that sounds personal. Applied after classification, so it holds whatever the
/// model thinks of a message; it only ever lowers Important to Neutral.
public enum QuietApps {
    public static func applying(
        to result: TriageResult,
        for notification: NotificationInput,
        policy: TriagePolicy,
        locale: Locale = .current
    ) -> TriageResult {
        guard result.category == .notifyNow,
              policy.isQuietApp(notification.source),
              !isExempt(result, notification: notification, policy: policy) else {
            return result
        }
        var quieted = TriageResult(
            category: .summary,
            confidence: result.confidence,
            reason: KaruiLocalization.string(
                "From a quiet app; only VIPs, codes, and urgent messages alert you.",
                locale: locale
            ),
            engine: result.engine,
            engineDetail: result.engineDetail,
            resolvedVIPIdentityID: result.resolvedVIPIdentityID,
            resolvedVIPDisplayName: result.resolvedVIPDisplayName,
            interest: result.interest
        )
        quieted.isModelFallback = result.isModelFallback
        quieted.rateLimitResetDate = result.rateLimitResetDate
        quieted.tags = result.tags
        quieted.modelDuration = result.modelDuration
        return quieted
    }

    public static func isExempt(_ result: TriageResult, notification: NotificationInput, policy: TriagePolicy) -> Bool {
        if result.resolvedVIPIdentityID != nil
            || ImportantPersonMatcher.resolveSender(notification.sender, identities: policy.vipIdentities) != nil {
            return true
        }
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
}
