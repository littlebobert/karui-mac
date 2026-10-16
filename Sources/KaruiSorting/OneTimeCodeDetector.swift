import Foundation

/// Finds verification codes so they can break through even when the message would
/// otherwise be quiet. iOS only auto-fills codes from Messages and Mail; under Focus,
/// codes from Slack, LINE, WhatsApp, or bank apps would otherwise arrive silently.
public enum OneTimeCodeDetector {
    /// Words that must appear near the number. Matched case-insensitively, as whole
    /// words for the Latin ones so "shopping" doesn't count as "pin" or "barcode" as
    /// "code"; "verif" and "authenticat" are prefixes.
    private static let keywordPattern = [
        #"(?<!\p{L})(?:(?:pass)?codes?|pins?|otps?|one[- ]time|2fa)(?!\p{L})"#,
        #"(?<!\p{L})(?:verif|authenticat)"#,
        "認証", "確認コード", "ワンタイム", "パスコード", "暗証番号", "인증", "확인 코드", "보안 코드", "일회용", "验证", "驗證"
    ].joined(separator: "|")
    /// How far, in characters, a keyword may be from the code.
    private static let keywordDistance = 40
    /// Characters that mask the rest of a card or account number: "••••8394".
    private static let maskCharacters: Set<Character> = ["•", "●", "*", "＊", "x", "X", "·", "・", "…"]
    private static let currencySymbols: Set<Character> = ["¥", "￥", "$", "€", "£", "₩"]

    /// Four to eight digits, optionally split into groups by one space or hyphen
    /// ("483921", "483 921", "48-39-21"), and not part of a longer number.
    /// Grouped forms come first so "1122 33" is not cut to "1122".
    private static let codePattern = #"(?<![\d\p{L}])(\d{3,4}[ -]\d{3,4}|\d{2}(?:[ -]\d{2}){1,2}|\d{4,8})(?![\d\p{L}])"#

    private static let keywordRegex = try! NSRegularExpression(pattern: keywordPattern, options: [.caseInsensitive])
    private static let codeRegex = try! NSRegularExpression(pattern: codePattern)

    public static func code(in notification: NotificationInput) -> String? {
        code(in: [notification.title, notification.body, notification.translatedText].compactMap { $0 }.joined(separator: "\n"))
    }

    public static func code(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        let keywords = keywordRegex.matches(in: text, range: range).map(\.range)
        guard !keywords.isEmpty else { return nil }
        let candidates = codeRegex.matches(in: text, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            let candidate = String(text[matchRange])
            let digits = candidate.filter(\.isNumber)
            guard (4...8).contains(digits.count),
                  !looksLikeYear(digits, in: candidate),
                  keywords.contains(where: { distance(between: $0, and: match.range(at: 1)) <= keywordDistance }),
                  !isMaskedOrAmount(matchRange, in: text) else {
                return nil
            }
            return candidate
        }
        // Prefer a code written as one run of digits over grouped ones, then the first.
        return candidates.first { !$0.contains(" ") && !$0.contains("-") } ?? candidates.first
    }

    private static func distance(between first: NSRange, and second: NSRange) -> Int {
        if NSIntersectionRange(first, second).length > 0 { return 0 }
        return first.location < second.location
            ? second.location - NSMaxRange(first)
            : first.location - NSMaxRange(second)
    }

    /// The end of a masked card number ("Visa ••••8394", "card ending in 8394") or an
    /// amount ("¥4200", "4200円") is never a code.
    private static func isMaskedOrAmount(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound].reversed().drop(while: { $0 == " " })
        if let previous = before.first, maskCharacters.contains(previous) || currencySymbols.contains(previous) {
            return true
        }
        let lead = String(text[..<range.lowerBound].suffix(12)).lowercased()
        if lead.hasSuffix("ending in ") || lead.hasSuffix("ending ") || lead.hasSuffix("末尾") {
            return true
        }
        let after = text[range.upperBound...].drop(while: { $0 == " " })
        return after.hasPrefix("円") || after.lowercased().hasPrefix("yen")
    }

    /// "2026" alone is far more often a year than a code.
    private static func looksLikeYear(_ digits: String, in candidate: String) -> Bool {
        digits.count == 4 && digits == candidate && (digits.hasPrefix("19") || digits.hasPrefix("20"))
    }
}
