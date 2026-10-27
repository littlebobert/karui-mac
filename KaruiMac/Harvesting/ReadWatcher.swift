import Foundation

/// The links sent today whose items haven't been read here yet, checked against
/// each app's own data on a timer and against notifications leaving Notification
/// Center. A read is reported once, then the link is forgotten; so is anything
/// older than a day, when its record on iCloud is gone anyway.
actor ReadWatcher {
    static let lifetime: TimeInterval = 24 * 60 * 60

    private struct Pending {
        let harvested: HarvestedLink
        let since: Date
    }

    private var pending: [String: Pending] = [:]

    func track(_ harvested: HarvestedLink, at date: Date = Date()) {
        pending[harvested.link.fingerprint] = Pending(harvested: harvested, since: date)
    }

    /// A link sent again under the iPhone's fingerprint, after a loose match: its read
    /// is reported under that one, which the inbox and the iPhone now know it by.
    func rename(_ fingerprint: String, to newFingerprint: String) {
        guard let item = pending.removeValue(forKey: fingerprint) else { return }
        var link = item.harvested.link
        link.fingerprint = newFingerprint
        let harvested = HarvestedLink(link: link, readProbe: item.harvested.readProbe, notificationID: item.harvested.notificationID)
        pending[newFingerprint] = Pending(harvested: harvested, since: item.since)
    }

    /// The links whose notification this was, if any; no longer tracked.
    func notificationDisappeared(id: Int64) -> [HarvestedLink] {
        let matched = pending.values.filter { $0.harvested.notificationID == id }.map(\.harvested)
        for link in matched { pending.removeValue(forKey: link.link.fingerprint) }
        return matched
    }

    /// The links whose items the apps now show as read; no longer tracked.
    func poll(using harvesters: HarvesterRegistry, now: Date = Date()) async -> [HarvestedLink] {
        pending = pending.filter { now.timeIntervalSince($0.value.since) <= Self.lifetime }
        var read: [HarvestedLink] = []
        for (fingerprint, item) in pending {
            guard let probe = item.harvested.readProbe, await harvesters.isRead(probe) == true else { continue }
            read.append(item.harvested)
            pending.removeValue(forKey: fingerprint)
        }
        return read
    }

    var count: Int { pending.count }
}
