import Foundation

/// Whether the person is using a Mac right now: one record per Mac, named like its
/// `Companion` record, updated every half minute while they are and at once when the
/// screen locks or the Mac sleeps. Karui on the iPhone reads it just before an alert,
/// and while they're at a Mac, alerts quietly: the Mac has the notification in front
/// of them. A record of its own, since the iPhone subscribes to `Companion` changes
/// for Sync Now and would be woken every half minute.
public enum MacPresenceRecordSchema {
    public static let recordType = "MacPresence"
    /// 1 while the person is using the Mac; 0 once it's idle, locked, or asleep.
    public static let isAtMac = "isAtMac"
    /// When it was last seen in use. A status older than `freshness` doesn't count: a
    /// Mac that lost its connection or shut its lid without a word goes quiet.
    public static let lastActiveAt = "lastActiveAt"
    public static let name = "name"
    /// How often the Mac writes while in use, and how stale a status may be.
    public static let interval: TimeInterval = 30
    public static let freshness: TimeInterval = 90
}
