import Foundation
import KaruiLinkKit

/// How to tell, later, that the person read the item on this Mac: where to look in
/// the app's own data.
enum ReadProbe: Equatable, Sendable {
    case spark(messagePrimaryKey: Int64)
    case slack(channelID: String, timestamp: String)
    case messages(guid: String)
}

/// A link for the iPhone, with what's needed to notice the item being read here.
struct HarvestedLink: Sendable {
    let link: DeepLinkRecord
    let readProbe: ReadProbe?
    /// The Notification Center record it came from; its disappearance also means
    /// read. Nil for a link made from the iPhone's verdict.
    let notificationID: Int64?
}

/// Turns one app's notification into the link that opens it on the iPhone, from
/// whatever that app leaves on the Mac. One per app; see Experiments/FINDINGS.md
/// for what each app offers.
protocol NotificationHarvester: Sendable {
    /// Lowercased bundle identifiers of the Mac app whose notifications this reads.
    var bundleIdentifiers: Set<String> { get }
    func harvest(_ record: NotificationRecord) async -> HarvestedLink?
    /// Whether the item was read on this Mac; nil for another app's probe, or when
    /// the app's data can't say.
    func isRead(_ probe: ReadProbe) async -> Bool?
}

struct HarvesterRegistry: Sendable {
    let harvesters: [any NotificationHarvester]

    var bundleIdentifiers: Set<String> {
        harvesters.reduce(into: []) { $0.formUnion($1.bundleIdentifiers) }
    }

    func harvest(_ record: NotificationRecord) async -> HarvestedLink? {
        guard let harvester = harvesters.first(where: { $0.bundleIdentifiers.contains(record.bundleIdentifier) }) else {
            return nil
        }
        return await harvester.harvest(record)
    }

    func isRead(_ probe: ReadProbe) async -> Bool? {
        for harvester in harvesters {
            if let answer = await harvester.isRead(probe) { return answer }
        }
        return nil
    }
}

extension NotificationRecord {
    /// Dated by the notification, unless the app knows better when its item arrived.
    func deepLink(as app: KnownApp, url: URL, opensExactContent: Bool, deliveredAt itemDate: Date? = nil) -> DeepLinkRecord {
        DeepLinkRecord(
            fingerprint: NotificationFingerprint.make(app: app.rawValue, title: title, subtitle: subtitle, body: body),
            app: app.rawValue,
            url: url,
            opensExactContent: opensExactContent,
            deliveredAt: itemDate ?? deliveredAt ?? Date()
        )
    }
}
