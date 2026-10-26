import Foundation

/// Telling the iPhone what to show now that the person has left the Mac. While they're
/// at a Mac, Karui on the iPhone holds Important alerts and marks each notification's
/// `Verdict` record with `VerdictRecordSchema.heldAt`. When the Mac sees them leave, it
/// looks up what was held and still unread and writes this record, one per Mac, named
/// "held-release-" and its `Companion` record's name. The iPhone's subscription to it
/// sends an alert push, and Karui's notification service extension turns that push
/// into the held alerts still unread, cancelling the ones read on the Mac. Only written
/// when something is unread: a push with nothing to show would still show something.
///
/// Fingerprints only, which the record names carry already, so the push can bring them
/// (`desiredKeys`) and the extension needn't reach iCloud.
public enum HeldReleaseRecordSchema {
    public static let recordType = "HeldRelease"
    public static let releasedAt = "releasedAt"
    /// Held and still unread: these are shown. One fingerprint to a line.
    public static let unread = "unread"
    /// Held and read on a Mac: these are cancelled.
    public static let read = "read"
    /// Held alerts go out on their own after this long anyway (the iPhone's fallback),
    /// so nothing older is looked for.
    public static let window: TimeInterval = 30 * 60

    public static func recordName(companionID: String) -> String { "held-release-" + companionID }

    public static func value(_ fingerprints: [String]) -> String { fingerprints.joined(separator: "\n") }

    public static func fingerprints(from value: String?) -> [String] {
        (value ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
