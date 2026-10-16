import Foundation

/// The iPhone's sorting settings, so Karui for Mac sorts a notification exactly as the
/// iPhone would: one record per iCloud account, written by the iPhone whenever they
/// change, while Show History on your Mac is on. Its fields are end-to-end encrypted.
public enum SortingSettingsRecordSchema {
    public static let recordType = "SortingSettings"
    public static let recordName = "sorting-settings"
    /// JSON of the iPhone's `TriagePolicy`, VIP photos left out. Encrypted.
    public static let policy = "policy"
    /// JSON of what Karui learned from History fixes: trigram hashes of the text, never
    /// the text. Empty when learning is off. Encrypted.
    public static let corrections = "corrections"
    /// How close a notification must be to a learned fix to be lowered.
    public static let correctionThreshold = "correctionThreshold"
    public static let updatedAt = "updatedAt"
    /// The iPhone app's version, so the Mac can tell settings from a newer Karui.
    public static let appVersion = "appVersion"
}
