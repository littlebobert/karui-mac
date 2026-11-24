import Foundation

/// Hide Emoji, set on the iPhone (Settings → History → Muting) and followed by Karui
/// for Mac: lists show their text without emoji, for everything or only for what
/// Karui kept quiet. A display preference, not a change to what's stored; opening a
/// notification shows it as it came.
public enum EmojiHiding {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off
        /// Neutral and Spam: the quiet rows, where emoji are mostly decoration.
        case quiet
        case all

        public var id: Self { self }
    }

    public static func hides(_ category: TriageCategory, mode: Mode) -> Bool {
        switch mode {
        case .off: false
        case .quiet: category != .notifyNow
        case .all: true
        }
    }

    /// The text without its emoji when the mode hides them for this category; the
    /// text as it came when that would leave nothing.
    public static func shown(_ text: String, category: TriageCategory, mode: Mode) -> String {
        guard hides(category, mode: mode) else { return text }
        let stripped = strip(text)
        return stripped.isEmpty ? text : stripped
    }

    /// The text without its emoji, including flags, keycaps, skin tones, and joined
    /// sequences, with the spaces they leave tidied. Digits, symbols like ©, and
    /// Japanese and Korean text stay.
    public static func strip(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if isEmoji(character) { continue }
            if character == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            result.append(character)
        }
        return result
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }

    public static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        // A keycap ("1️⃣") or a joined sequence counts whole; a lone digit or # doesn't.
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiModifier || $0.value == 0x200D || $0.value == 0x20E3 }) {
            return character.unicodeScalars.count > 1
        }
        if first.properties.isEmojiPresentation { return true }
        // Text-default symbols shown as emoji through a variation selector ("☀️").
        if first.properties.isEmoji, character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return true }
        // Pictographs without a presentation flag but outside the ASCII and symbol
        // blocks ("🛜" in newer Unicode); digits and © are below.
        return first.properties.isEmoji && first.value >= 0x1F000
    }
}
