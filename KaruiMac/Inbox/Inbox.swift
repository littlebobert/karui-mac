import Foundation
import KaruiLinkKit
import Observation

/// The day's notifications from the apps the Mac watches, as Notification Center
/// has them, with what Karui on the iPhone decided about each and the link that
/// opens it. In memory; Notification Center and iCloud are the records.
@MainActor
@Observable
final class Inbox {
    struct Item: Identifiable {
        /// Notification Center's record ID, or the fingerprint for one only the iPhone got.
        let id: String
        let app: String
        let fingerprint: String
        let title: String?
        let subtitle: String?
        let body: String?
        let deliveredAt: Date
        var link: DeepLinkRecord?
        var readAt: Date?
        var verdict: VerdictRecord?

        var isUnread: Bool { readAt == nil && verdict?.isUnread ?? true }

        /// A verdict arrives within a minute or two when the iPhone got the
        /// notification; after this long, it didn't (the app held the push back
        /// while the person was at the Mac, or the phone was off).
        static let verdictWait: TimeInterval = 5 * 60
        var isWaitingForVerdict: Bool {
            verdict == nil && Date().timeIntervalSince(deliveredAt) < Self.verdictWait
        }
    }

    private(set) var items: [Item] = []
    private static let capacity = 500

    static func id(for record: NotificationRecord) -> String { "notification-\(record.id)" }

    /// A notification this Mac got, from Notification Center.
    func add(_ record: NotificationRecord, as app: KnownApp) {
        insert(Item(
            id: Self.id(for: record),
            app: app.rawValue,
            fingerprint: record.deepLink(as: app, url: URL(string: "about:blank")!, opensExactContent: false).fingerprint,
            title: record.title,
            subtitle: record.subtitle,
            body: record.body,
            deliveredAt: record.deliveredAt ?? Date()
        ))
    }

    /// The day's verdicts from the iPhone: each goes with its notification here, or,
    /// when it carries the text, stands for a notification only the iPhone got.
    func apply(_ verdicts: [VerdictRecord]) {
        for verdict in verdicts {
            if items.contains(where: { $0.fingerprint == verdict.fingerprint }) {
                setVerdict(verdict, for: verdict.fingerprint)
            } else if verdict.title != nil || verdict.body != nil {
                var item = Item(
                    id: verdict.fingerprint,
                    app: verdict.app,
                    fingerprint: verdict.fingerprint,
                    title: verdict.title,
                    subtitle: nil,
                    body: verdict.body,
                    deliveredAt: verdict.triagedAt
                )
                item.verdict = verdict
                insert(item)
            }
        }
    }

    func setLink(_ link: DeepLinkRecord, for record: NotificationRecord) {
        update(Self.id(for: record)) { $0.link = link; $0.readAt = link.readAt }
    }

    /// Newest first; an item already there keeps its place.
    private func insert(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        let index = items.firstIndex { $0.deliveredAt < item.deliveredAt } ?? items.endIndex
        items.insert(item, at: index)
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
    }

    func markRead(fingerprint: String, at date: Date = Date()) {
        for index in items.indices where items[index].fingerprint == fingerprint {
            items[index].readAt = date
        }
    }

    func setVerdict(_ verdict: VerdictRecord, for fingerprint: String) {
        for index in items.indices where items[index].fingerprint == fingerprint {
            items[index].verdict = verdict
        }
    }

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
