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

    public init(id: String, name: String, appVersion: String, lastSeenAt: Date, apps: [String]) {
        self.id = id
        self.name = name
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.apps = apps
    }
}

public enum CompanionRecordSchema {
    public static let recordType = "Companion"
    public static let name = "name"
    public static let appVersion = "appVersion"
    public static let lastSeenAt = "lastSeenAt"
    public static let apps = "apps"
}
