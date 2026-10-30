import Foundation

public struct RuleBasedClassifier: NotificationClassifying {

    public init(
    ) {
    }
    /// The confidence of the fallback's "nothing matched" Neutral. Rate-limited items
    /// with this result are the uncertain ones worth a recheck.
    public static let defaultNeutralConfidence = 0.62

    public func classify(_ notification: NotificationInput, policy: TriagePolicy) async -> TriageResult {
        classifySynchronously(notification, policy: policy)
    }

    public func classifySynchronously(_ notification: NotificationInput, policy: TriagePolicy) -> TriageResult {
        let source = notification.source.lowercased()
        let titleAndBody = "\(notification.title) \(notification.body)".lowercased()
        let sender = notification.sender?.lowercased() ?? ""
        let translatedText = notification.translatedText?.lowercased() ?? ""
        let allText = "\(source) \(sender) \(titleAndBody) \(translatedText)"

        if let handoff = CallHandoffDetector.result(for: notification) {
            return handoff
        }

        if let resolution = ImportantPersonMatcher.resolveSender(
            notification.sender,
            identities: policy.vipIdentities
        ) {
            return result(
                .notifyNow,
                confidence: 0.96,
                reason: KaruiLocalization.formatted("Message from important contact “%@”.", resolution.identity.displayName),
                resolution: resolution
            )
        }

        if let mentionedName = UserMentionDetector.mentionedName(
            in: notification,
            userNames: policy.commaSeparatedValues(from: policy.userNames)
        ) {
            return result(.notifyNow, confidence: 0.96, reason: KaruiLocalization.formatted("Mentions you as “@%@”.", mentionedName))
        }

        if let matchedUrgentTerm = Self.firstMatch(in: allText, terms: policy.terms(from: policy.urgentKeywords)) {
            return result(.notifyNow, confidence: 0.94, reason: KaruiLocalization.formatted("Matches urgent term “%@”.", matchedUrgentTerm))
        }

        if notification.isTimeSensitive == true {
            return result(.notifyNow, confidence: 0.98, reason: KaruiLocalization.string("Marked time sensitive by the source app."))
        }

        let calendarOrTravelTerms = [
            "calendar", "flight", "boarding", "gate", "train", "appointment", "meeting starts",
            "カレンダー", "フライト", "搭乗", "搭乗口", "新幹線", "会議開始",
            "항공편", "탑승", "탑승구", "KTX", "회의 시작",
            "Kalender", "Flug", "Abflug", "Zug", "Termin", "Meeting beginnt"
        ]
        if policy.prioritizeCalendarAndTravel,
           let matchedTravelTerm = Self.firstMatch(in: allText, terms: calendarOrTravelTerms) {
            return result(.notifyNow, confidence: 0.90, reason: KaruiLocalization.formatted("Time-sensitive calendar or travel signal “%@”.", matchedTravelTerm))
        }

        let promotionTerms = [
            "sale", "discount", "% off", "limited time", "shop now", "promo",
            "セール", "割引", "%オフ", "％オフ", "期間限定", "今すぐ購入",
            "세일", "할인", "% 할인", "기간 한정", "지금 구매",
            "Rabatt", "% Rabatt", "nur für kurze Zeit", "jetzt kaufen", "jetzt shoppen"
        ]
        if policy.silencePromotions,
           let matchedPromotion = Self.firstMatch(in: allText, terms: promotionTerms) {
            return result(.silence, confidence: 0.95, reason: KaruiLocalization.formatted("Promotional signal “%@”.", matchedPromotion))
        }

        if let matchedSilenceTerm = Self.firstMatch(in: allText, terms: policy.terms(from: policy.silenceKeywords)) {
            return result(.silence, confidence: 0.92, reason: KaruiLocalization.formatted("Matches silence term “%@”.", matchedSilenceTerm))
        }

        if let matchedSummaryTerm = Self.firstMatch(in: allText, terms: policy.terms(from: policy.summaryKeywords)) {
            return result(.summary, confidence: 0.88, reason: KaruiLocalization.formatted("Matches summary term “%@”.", matchedSummaryTerm))
        }

        if let importantApp = ImportantAppMatcher.matchingApp(
            for: notification.source,
            in: policy.importantApps(activeAt: .now)
        ) {
            return result(.notifyNow, confidence: 0.70, reason: KaruiLocalization.formatted("From important app “%@”.", importantApp))
        }

        return result(.summary, confidence: Self.defaultNeutralConfidence, reason: KaruiLocalization.string("No urgent or suppressible rule matched; keep for review."))
    }

    public static func firstMatch(in text: String, terms: [String]) -> String? {
        terms.first { term in
            containsBoundedTerm(term, in: text)
        }
    }

    private static func containsBoundedTerm(_ term: String, in text: String) -> Bool {
        let escapedTerm = NSRegularExpression.escapedPattern(for: term)
        let startsWithWordCharacter = term.unicodeScalars.first.map(needsWordBoundary) ?? false
        let endsWithWordCharacter = term.unicodeScalars.last.map(needsWordBoundary) ?? false
        let leadingBoundary = startsWithWordCharacter ? "(?<![\\p{L}\\p{N}])" : ""
        let trailingBoundary: String
        if endsWithWordCharacter {
            // Korean attaches particles straight to a word, Latin ones included (KTX가,
            // urgent입니다), so Hangul can follow; any other letter or digit can't.
            trailingBoundary = "(?![[\\p{L}\\p{N}]--[\\u1100-\\u11FF\\u3130-\\u318F\\uAC00-\\uD7A3]])"
        } else if term.unicodeScalars.last.map(isKatakana) == true {
            // A katakana word runs until the katakana does: セール (sale) is inside
            // セールス (sales) and セールスフォース (Salesforce). Compounds usually add to
            // the front (タイムセール) or continue in kanji (セール中), which still match.
            trailingBoundary = "(?![\\u30A1-\\u30FA\\u30FC])"
        } else {
            trailingBoundary = ""
        }
        let pattern = "\(leadingBoundary)\(escapedTerm)\(trailingBoundary)"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A1...0x30FA).contains(scalar.value) || scalar.value == 0x30FC
    }

    /// Japanese and Chinese text has no spaces between words, and Korean attaches
    /// particles and endings to them (할인중, 긴급합니다), so terms that start or end
    /// with those characters match anywhere instead of requiring a word boundary.
    private static func needsWordBoundary(_ scalar: Unicode.Scalar) -> Bool {
        guard CharacterSet.alphanumerics.contains(scalar) else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3:
            return false
        default:
            return true
        }
    }

    private func result(
        _ category: TriageCategory,
        confidence: Double,
        reason: String,
        resolution: VIPIdentityResolution? = nil
    ) -> TriageResult {
        TriageResult(
            category: category,
            confidence: confidence,
            reason: reason,
            engine: .deterministicRules,
            resolvedVIPIdentityID: resolution?.identity.id,
            resolvedVIPDisplayName: resolution?.identity.displayName
        )
    }
}
