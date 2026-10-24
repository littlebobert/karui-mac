import Foundation

/// A sender the person silenced from History, in the app they wrote from: whatever
/// a model makes of their notifications there, they're Spam. By the name the
/// notifications show, as Saved Contacts exceptions are.
public struct SilencedSender: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var app: String

    public init(name: String, app: String) {
        self.name = name
        self.app = app
    }

    public var id: String { "\(ImportantAppMatcher.canonicalKey(app))|\(TriagePolicy.normalizedSenderName(name))" }

    public var displayName: String { Self.displayName(name) }

    /// The sender as people read it, without an email address after the name:
    /// "BrightBox Deals" for "BrightBox Deals <offers@brightbox.example>". Matching
    /// still uses the whole sender.
    public static func displayName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else { return trimmed }
        let name = trimmed[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? trimmed : name
    }
}

/// Applied after classification, as Quiet Apps are, so it holds whatever the model
/// thinks: a silenced sender's notification is Spam. A VIP is never silenced, and the
/// rules that decide before the model (codes, @mentions, Important Conversations)
/// still alert.
public enum SilencedSenders {
    public static func applying(
        to result: TriageResult,
        for notification: NotificationInput,
        policy: TriagePolicy,
        locale: Locale = .current
    ) -> TriageResult {
        guard result.category != .silence,
              policy.isSilencedSender(notification.sender, in: notification.source),
              result.resolvedVIPIdentityID == nil,
              ImportantPersonMatcher.resolveSender(notification.sender, identities: policy.vipIdentities) == nil else {
            return result
        }
        var silenced = TriageResult(
            category: .silence,
            confidence: result.confidence,
            reason: KaruiLocalization.string("From a sender you silenced.", locale: locale),
            engine: result.engine,
            engineDetail: result.engineDetail,
            resolvedVIPIdentityID: result.resolvedVIPIdentityID,
            resolvedVIPDisplayName: result.resolvedVIPDisplayName,
            interest: result.interest
        )
        silenced.isModelFallback = result.isModelFallback
        silenced.rateLimitResetDate = result.rateLimitResetDate
        silenced.tags = result.tags
        silenced.modelDuration = result.modelDuration
        return silenced
    }
}
