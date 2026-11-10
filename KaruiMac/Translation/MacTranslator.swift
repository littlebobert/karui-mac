import Foundation
import KaruiSorting
import NaturalLanguage
import Synchronization
@preconcurrency import Translation

/// The separate parts of a notification, so each is translated only if it needs it.
/// As Karui on the iPhone has them (`TranslatableNotificationFields` there).
struct TranslatableFields: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let body: String
    /// Kept out of language detection when it's also the title.
    let sender: String?

    /// Prefers the body, because titles are often just a sender's name.
    var languageCode: String? {
        if let code = NotificationLanguageDetector.languageCode(for: body)
            ?? NotificationLanguageDetector.languageCode(for: [subtitle, body].compactMap { $0 }.joined(separator: "\n")) {
            return code
        }
        // A sender's name says nothing about the message.
        guard !titleIsSender else { return nil }
        return NotificationLanguageDetector.languageCode(for: [title, subtitle, body].compactMap { $0 }.joined(separator: "\n"))
    }

    private var titleIsSender: Bool {
        guard let sender else { return false }
        func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalized(title) == normalized(sender)
    }
}

/// The language a notification is in, as the iPhone detects it.
enum NotificationLanguageDetector {
    static let minimumLetterCount = 8
    static let minimumConfidence = 0.6

    /// Nil for short or ambiguous text.
    static func languageCode(for text: String) -> String? {
        let text = strippingNames(from: text)
        guard weightedLetterCount(text) >= minimumLetterCount else { return nil }
        // Kana is only Japanese and hangul only Korean; @handles and #channels have
        // read as Indonesian.
        if let scriptLanguage = languageByScript(text) { return scriptLanguage }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= minimumConfidence else { return nil }
        return TranslationLanguages.key(for: language.rawValue)
    }

    /// @handles, #channels, email addresses, and links say nothing about the language.
    static func strippingNames(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?:https?://\S+|[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.\p{L}+|[@#][\p{L}\p{N}_.-]+)"#,
            with: " ",
            options: .regularExpression
        )
    }

    /// "ja" or "ko" when kana or hangul carries at least half the weighted letters;
    /// nil leaves it to the recognizer. Han alone could be Chinese or Japanese.
    static func languageByScript(_ text: String) -> String? {
        var kana = 0, hangul = 0, han = 0, total = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 2; total += 2
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: hangul += 2; total += 2
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: han += 2; total += 2
            default: total += 1
            }
        }
        guard total > 0 else { return nil }
        if kana > 0, (kana + han) * 2 >= total { return "ja" }
        if hangul > 0, (hangul + han) * 2 >= total { return "ko" }
        return nil
    }

    /// Korean, Japanese, and Chinese characters each carry roughly a word's worth of
    /// meaning, so they count double toward the minimum.
    private static func weightedLetterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            guard CharacterSet.letters.contains(scalar) else { return count }
            switch scalar.value {
            case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
                return count + 2
            default:
                return count + 1
            }
        }
    }
}

/// Translates notifications on this Mac with Apple's Translation framework, as Karui
/// on the iPhone does there, following the iPhone's Translate Notifications setting
/// and the languages it reads (synced with its sorting settings). Into this Mac's
/// language. The fast models first when their language pack is downloaded on this
/// Mac, then Apple Intelligence's. Nothing leaves the Mac.
enum MacTranslator {
    /// Whether a notification in this language is one to translate for this person.
    static func shouldTranslate(_ languageKey: String?, policy: TriagePolicy, target: String = TranslationLanguages.targetLanguageKey) -> Bool {
        guard policy.translateNotifications, let languageKey else { return false }
        return !TranslationLanguages.reads(languageKey, readLanguages: policy.readLanguages) && languageKey != target
    }

    /// Which fields to translate. Title and subtitle only when detected as the source
    /// language, since they're often names or channels. The body unless it's detected as
    /// a different language; short bodies can't be, so they follow the notification's.
    static func fieldsNeedingTranslation(_ fields: TranslatableFields, from sourceKey: String) -> [(identifier: String, text: String)] {
        var needed: [(identifier: String, text: String)] = []
        func isNonempty(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isNonempty(fields.title), NotificationLanguageDetector.languageCode(for: fields.title) == sourceKey {
            needed.append(("title", fields.title))
        }
        if let subtitle = fields.subtitle, isNonempty(subtitle), NotificationLanguageDetector.languageCode(for: subtitle) == sourceKey {
            needed.append(("subtitle", subtitle))
        }
        let bodyLanguage = NotificationLanguageDetector.languageCode(for: fields.body)
        if isNonempty(fields.body), bodyLanguage == nil || bodyLanguage == sourceKey {
            needed.append(("body", fields.body))
        }
        return needed
    }

    /// The translation, or nil when the notification is in a language the person reads,
    /// translation is off, or no model for the pair is on this Mac.
    @available(macOS 26.4, *)
    static func translate(_ fields: TranslatableFields, policy: TriagePolicy) async -> NotificationTranslation? {
        let target = TranslationLanguages.targetLanguageKey
        guard let source = fields.languageCode, shouldTranslate(source, policy: policy, target: target),
              !fieldsNeedingTranslation(fields, from: source).isEmpty else { return nil }
        for quality in [TranslationQuality.fast, .high] {
            guard let pair = await installedPair(from: source, to: target, quality: quality) else { continue }
            let session = TranslationSession(installedSource: pair.source, target: pair.target, preferredStrategy: strategy(for: quality))
            let start = ContinuousClock.now
            do {
                let translation = try await translate(fields, from: source, to: target, quality: quality, using: session)
                SafeDiagnosticLog.shared.record("translation: \(source)→\(target) (\(quality.rawValue)) in \(start.duration(to: .now))")
                return translation
            } catch {
                SafeDiagnosticLog.shared.record("translation: \(source)→\(target) (\(quality.rawValue)) failed: \(error.localizedDescription)")
            }
        }
        SafeDiagnosticLog.shared.record("translation: \(source)→\(target) unavailable on this Mac")
        return nil
    }

    @available(macOS 26.4, *)
    private static func translate(
        _ fields: TranslatableFields,
        from sourceKey: String,
        to targetKey: String,
        quality: TranslationQuality,
        using session: TranslationSession
    ) async throws -> NotificationTranslation {
        let requests = fieldsNeedingTranslation(fields, from: sourceKey).map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.identifier)
        }
        let responses = try await session.translations(from: requests)
        let translated = { (identifier: String) in responses.first { $0.clientIdentifier == identifier }?.targetText }
        return NotificationTranslation(
            sourceLanguage: sourceKey,
            targetLanguage: targetKey,
            title: translated("title"),
            subtitle: translated("subtitle") ?? fields.subtitle,
            body: translated("body") ?? fields.body,
            translatedAt: .now,
            quality: quality
        )
    }

    /// A specific source and target installed for this quality, such as Japanese
    /// (Japan) → English (US): generic languages can pass Apple's check and still fail.
    @available(macOS 26.4, *)
    private static func installedPair(
        from sourceKey: String,
        to targetKey: String,
        quality: TranslationQuality
    ) async -> (source: Locale.Language, target: Locale.Language)? {
        let supported = await LanguageAvailability().supportedLanguages
        let isSupported = { (key: String) in supported.contains { TranslationLanguages.key(for: $0.minimalIdentifier) == key } }
        guard isSupported(sourceKey), isSupported(targetKey) else { return nil }
        let availability = LanguageAvailability(preferredStrategy: strategy(for: quality))
        for source in variants(of: sourceKey, in: supported) {
            for target in variants(of: targetKey, in: supported) {
                if await availability.status(from: source, to: target) == .installed { return (source, target) }
            }
        }
        return nil
    }

    /// Supported variants of a language, best match first: the region from the person's
    /// language settings, then their region, then the language's default.
    static func variants(
        of key: String,
        in supported: [Locale.Language],
        preferredLanguages: [String] = Locale.preferredLanguages,
        currentRegion: Locale.Region? = Locale.current.region
    ) -> [Locale.Language] {
        let matches = supported.filter { TranslationLanguages.key(for: $0.minimalIdentifier) == key }
        guard !matches.isEmpty else { return [Locale.Language(identifier: key)] }
        let settingsRegions = preferredLanguages
            .map(Locale.Language.init(identifier:))
            .filter { TranslationLanguages.key(for: $0.minimalIdentifier) == key }
            .compactMap(\.region)
        let defaultRegion = Locale.Language(identifier: Locale.Language(identifier: key).maximalIdentifier).region
        let preferredRegions = settingsRegions + [currentRegion, defaultRegion].compactMap { $0 }
        return matches.sorted { lhs, rhs in
            let lhsRank = lhs.region.flatMap { preferredRegions.firstIndex(of: $0) } ?? preferredRegions.count
            let rhsRank = rhs.region.flatMap { preferredRegions.firstIndex(of: $0) } ?? preferredRegions.count
            return lhsRank < rhsRank
        }
    }

    @available(macOS 26.4, *)
    private static func strategy(for quality: TranslationQuality) -> TranslationSession.Strategy {
        quality == .fast ? .lowLatency : .highFidelity
    }

    /// The task's value if it finishes within `deadline`, else nil; the task keeps running.
    static func value<T: Sendable>(of task: Task<T?, Never>, within deadline: Duration) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(returning: await task.value) }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(returning: nil)
            }
        }
    }
}

/// Resumes a continuation only once, whichever caller gets there first.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: T) {
        let pending = continuation.withLock { continuation -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
