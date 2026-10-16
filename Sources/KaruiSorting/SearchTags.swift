import Foundation
import OSLog

/// Search tags: a few words naming what a notification is about, in the languages
/// the person reads, written by the on-device model when it sorts the notification
/// and kept in History's search index. "dentist" then finds the appointment reminder
/// that never says dentist. Items sorted by the rules, or before tags existed, get
/// theirs from `HistoryTagging`, a foreground pass.
public enum SearchTags {
    /// The languages tags and search terms are written in, as the model names them:
    /// what the person reads.
    public static func languages(readLanguages: [String], locale: Locale = .current) -> [String] {
        var names: [String] = []
        for key in TranslationLanguages.effectiveReadLanguageKeys(readLanguages) {
            let name = KaruiLocalization.modelLanguageName(Locale(identifier: key))
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? [KaruiLocalization.modelLanguageName(locale)] : names
    }

    public static let maximumCount = 6
    public static let maximumLength = 40
    public static let logger = Logger(subsystem: "com.justin.henry.karui", category: "SearchTags")

    /// Appended to the sorting instructions, so tags come with the decision.
    public static func instructions(languages: [String]) -> String {
        """
        Search tags: also give three to five tags of one to three words each, naming what this \
        notification is about so the person can find it later: the specific subject (the \
        company, service, place, or event), the kind of event or request, and the sender's \
        purpose. Prefer specific tags like "dentist appointment" or "domain renewal" to generic \
        ones like "update", "message", or "notification". Prefer words that don't already appear \
        in the notification: a synonym, the category it belongs to, or its name in another \
        language; a tag that only repeats the text adds nothing, since the text itself can be \
        searched. Not the app's name. Give each tag in every one of these languages: \
        \(languages.joined(separator: ", ")).
        """
    }

    /// Trimmed, deduplicated, and capped; nil when nothing usable came back.
    public static func cleaned(_ tags: [String]) -> [String]? {
        var result: [String] = []
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !cleaned.isEmpty, cleaned.count <= maximumLength,
                  !result.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { continue }
            result.append(cleaned)
            if result.count == maximumCount { break }
        }
        return result.isEmpty ? nil : result
    }
}
