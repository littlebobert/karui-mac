import Foundation

private final class KaruiLocalizationBundleToken: NSObject {}

public enum KaruiLocalization {
    private static let localizationBundle = Bundle(for: KaruiLocalizationBundleToken.self)

    public static func string(_ key: String, locale: Locale = .current) -> String {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        // A regional variant first, such as en-GB for UK spellings, then the language.
        var candidates = [locale.region.map { "\(languageCode)-\($0.identifier)" }, languageCode].compactMap { $0 }
        // For the person's own locale, the language they chose comes first, as it does
        // for the rest of the app: English (UK) with the region set to Japan is en_JP,
        // which the region alone would give US English.
        if locale.identifier == Locale.current.identifier,
           let preferred = localizationBundle.preferredLocalizations.first {
            candidates.insert(preferred, at: 0)
        }
        let localizedBundle = candidates.lazy
            .compactMap { localizationBundle.path(forResource: $0, ofType: "lproj") }
            .compactMap(Bundle.init(path:))
            .first ?? localizationBundle
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func formatted(_ key: String, _ arguments: CVarArg..., locale: Locale = .current) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    public static func isJapanese(_ locale: Locale = .current) -> Bool {
        locale.language.languageCode == .japanese
    }

    public static func isKorean(_ locale: Locale = .current) -> Bool {
        locale.language.languageCode == .korean
    }

    /// The language Apple's models should write in for this person, as an instruction
    /// word: Japanese and Korean get their own; everyone else gets English.
    public static func modelLanguageName(_ locale: Locale = .current) -> String {
        if isJapanese(locale) { return "Japanese" }
        if isKorean(locale) { return "Korean" }
        return "English"
    }
}
