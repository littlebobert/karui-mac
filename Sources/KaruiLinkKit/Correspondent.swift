import CryptoKit
import Foundation

/// People the person has written to, as the Mac finds them in its mail and messages
/// and the iPhone meets them in notifications: addresses, numbers, and names, each
/// reduced to a hash so the list itself says nothing. A notification's sender is
/// hashed the same way on the iPhone and looked up.
public enum CorrespondentHash {
    /// The hash of one handle or name, or nil when there's nothing to hash.
    public static func make(_ handle: String) -> String? {
        let normalized = normalize(handle)
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercased and trimmed; a phone number keeps only its digits and a leading
    /// plus, so "+81 90-1234-5678" and "+819012345678" are one person; a name has its
    /// runs of whitespace collapsed.
    public static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        let looksLikeNumber = digits.count >= 6
            && trimmed.allSatisfy { $0.isNumber || $0.isWhitespace || "+-().".contains($0) }
        if looksLikeNumber {
            return (trimmed.hasPrefix("+") ? "+" : "") + digits
        }
        return trimmed
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

/// One record per Mac, refreshed daily: the hashes, and how many people that is.
public enum CorrespondentRecordSchema {
    public static let recordType = "Correspondents"
    public static let hashes = "hashes"
    public static let count = "count"
    public static let updatedAt = "updatedAt"
    /// Enough for anyone; a CloudKit record holds a megabyte.
    public static let maximumHashes = 8000
}
