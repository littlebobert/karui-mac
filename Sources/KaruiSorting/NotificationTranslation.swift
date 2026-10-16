import Foundation

/// Title is set only when it was translated. Subtitle and body are ready to display:
/// translated when they were in the source language, otherwise the original text.
public struct NotificationTranslation: Codable, Equatable, Sendable {
    public let sourceLanguage: String
    public let targetLanguage: String
    public let title: String?
    public var subtitle: String? = nil
    public let body: String?
    public let translatedAt: Date
    /// Nil for translations saved before quality was tracked; those used the default
    /// Apple Intelligence model, so they count as high quality.
    public var quality: TranslationQuality? = nil

    public init(
        sourceLanguage: String,
        targetLanguage: String,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        translatedAt: Date,
        quality: TranslationQuality? = nil
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.translatedAt = translatedAt
        self.quality = quality
    }

    public var isHighQuality: Bool { quality != .fast }

    /// Subtitle and body on separate lines, matching how Karui shows notification text.
    public var displayBody: String? {
        let text = [subtitle, body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
public enum TranslationLanguages {
    /// A comparable key for a language: the language code, plus the script for Chinese
    /// so Simplified and Traditional stay distinct.
    public static func key(for identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return identifier }
        if code == "zh",
           let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier {
            return "zh-\(script)"
        }
        return code
    }

    public static var deviceLanguageKeys: [String] {
        uniqueKeys(Locale.preferredLanguages)
    }

    /// Empty means the person hasn't customized the list, so the device languages apply.
    public static func effectiveReadLanguageKeys(_ readLanguages: [String]) -> [String] {
        readLanguages.isEmpty ? deviceLanguageKeys : uniqueKeys(readLanguages)
    }

    public static func reads(_ languageKey: String, readLanguages: [String]) -> Bool {
        effectiveReadLanguageKeys(readLanguages).contains(key(for: languageKey))
    }

    /// Translations go into the language Karui's UI is running in.
    public static var targetLanguageKey: String {
        key(for: Locale.current.identifier)
    }

    public static func displayName(for languageKey: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: languageKey) ?? languageKey
    }

    public static func uniqueKeys(_ identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        return identifiers.map(key(for:)).filter { seen.insert($0).inserted }
    }
}

/// `.fast` uses Apple's traditional translation models (`.lowLatency`), which meet the
/// Shortcut's deadline. `.high` uses Apple Intelligence (`.highFidelity`).
public enum TranslationQuality: String, Codable, Sendable {
    case fast
    case high
}
