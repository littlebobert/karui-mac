import Foundation

/// One record per Mac running Karui for Mac, refreshed while it runs, so the
/// iPhone knows a Mac is sending links, which apps it covers, and when it was last
/// seen. The Mac's name and app version are all it says about the Mac.
public struct CompanionRecord: Codable, Equatable, Sendable {
    /// Stable per Mac; the record's name.
    public var id: String
    public var name: String
    public var appVersion: String
    public var lastSeenAt: Date
    /// `KnownApp` names the Mac harvests links for.
    public var apps: [String]
    /// When the person pressed Sync Now on the Mac. The iPhone subscribes to it and
    /// sends its History and picks up the Mac's actions on the resulting push.
    public var syncRequestedAt: Date?

    public init(id: String, name: String, appVersion: String, lastSeenAt: Date, apps: [String], syncRequestedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.apps = apps
        self.syncRequestedAt = syncRequestedAt
    }
}

public enum CompanionRecordSchema {
    public static let recordType = "Companion"
    public static let name = "name"
    public static let appVersion = "appVersion"
    public static let lastSeenAt = "lastSeenAt"
    public static let apps = "apps"
    public static let syncRequestedAt = "syncRequestedAt"
}
