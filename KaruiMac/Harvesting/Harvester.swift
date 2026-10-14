import Foundation
import KaruiLinkKit

/// Turns one app's notification into the link that opens it on the iPhone, from
/// whatever that app leaves on the Mac. One per app; see Experiments/FINDINGS.md
/// for what each app offers.
protocol NotificationHarvester: Sendable {
    /// Lowercased bundle identifiers of the Mac app whose notifications this reads.
    var bundleIdentifiers: Set<String> { get }
    func harvest(_ record: NotificationRecord) async -> DeepLinkRecord?
}

struct HarvesterRegistry: Sendable {
    let harvesters: [any NotificationHarvester]

    var bundleIdentifiers: Set<String> {
        harvesters.reduce(into: []) { $0.formUnion($1.bundleIdentifiers) }
    }

    func harvest(_ record: NotificationRecord) async -> DeepLinkRecord? {
        guard let harvester = harvesters.first(where: { $0.bundleIdentifiers.contains(record.bundleIdentifier) }) else {
            return nil
        }
        return await harvester.harvest(record)
    }
}

extension NotificationRecord {
    func deepLink(as app: KnownApp, url: URL, opensExactContent: Bool) -> DeepLinkRecord {
        DeepLinkRecord(
            fingerprint: NotificationFingerprint.make(app: app.rawValue, title: title, subtitle: subtitle, body: body),
            app: app.rawValue,
            url: url,
            opensExactContent: opensExactContent,
            deliveredAt: deliveredAt ?? Date()
        )
    }
}
