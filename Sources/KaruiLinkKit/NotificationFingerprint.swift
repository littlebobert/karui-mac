import CryptoKit
import Foundation

/// Identifies one notification the same way on the iPhone and on the Mac without
/// keeping its text. Karui's alert on the iPhone and the Mac's record of the same
/// notification meet on this value, so both build it from the same fields: the app's
/// name as Karui knows it, then the notification's title, subtitle, and the start of
/// its body. When the notification arrived is matched separately, with some slack.
public enum NotificationFingerprint {
    /// Marks that are invisible, which one platform may keep and the other drop:
    /// marketing mail pads its preview text with these.
    static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{034F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{00AD}", "\u{FEFF}", "\u{2060}"
    ]

    /// Each platform cuts a long body short at its own length (macOS keeps about 160
    /// characters), so only the start counts.
    static let bodyPrefixLength = 60

    public static func make(app: String, title: String?, subtitle: String?, body: String?) -> String {
        let fields = [
            normalize(app),
            normalize(title),
            normalize(subtitle),
            String(normalize(body).prefix(bodyPrefixLength))
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compatibility-normalized, stripped of invisible marks, runs of whitespace
    /// collapsed to one space, trimmed, lowercased.
    public static func normalize(_ text: String?) -> String {
        guard let text else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars
        where !invisibleScalars.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
