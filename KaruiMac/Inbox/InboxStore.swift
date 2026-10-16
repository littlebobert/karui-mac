import Foundation
import KaruiLinkKit
import SwiftData

/// One inbox item on disk: the notification as Notification Center had it (or as
/// the iPhone sent it), the link, the read mark, and the iPhone's verdict.
@Model
final class InboxEntry {
    @Attribute(.unique) var id: String
    var app: String
    var fingerprint: String
    var title: String?
    var subtitle: String?
    var body: String?
    var deliveredAt: Date
    var recipients: String?
    var senderName: String?
    var linkURL: String?
    var opensExactContent: Bool
    var readAt: Date?
    var chosenCategory: String?
    var verdictCategory: String?
    var verdictInterest: Int?
    var verdictReason: String?
    var verdictTriagedAt: Date?
    var verdictIsUnread: Bool
    var verdictTitle: String?
    var verdictBody: String?
    /// The Mac's own verdict (`MacVerdict`), as JSON.
    var macVerdictData: Data?

    init(item: Inbox.Item) {
        id = item.id
        app = item.app
        fingerprint = item.fingerprint
        title = item.title
        subtitle = item.subtitle
        body = item.body
        deliveredAt = item.deliveredAt
        recipients = item.recipients
        senderName = item.senderName
        linkURL = item.link?.url.absoluteString
        opensExactContent = item.link?.opensExactContent ?? false
        readAt = item.readAt
        chosenCategory = item.chosenCategory
        verdictCategory = item.verdict?.category
        verdictInterest = item.verdict?.interest
        verdictReason = item.verdict?.reason
        verdictTriagedAt = item.verdict?.triagedAt
        verdictIsUnread = item.verdict?.isUnread ?? true
        verdictTitle = item.verdict?.title
        verdictBody = item.verdict?.body
        macVerdictData = item.macVerdict.flatMap { try? JSONEncoder().encode($0) }
    }

    func update(from item: Inbox.Item) {
        fingerprint = item.fingerprint
        recipients = item.recipients
        senderName = item.senderName
        linkURL = item.link?.url.absoluteString
        opensExactContent = item.link?.opensExactContent ?? false
        readAt = item.readAt
        chosenCategory = item.chosenCategory
        verdictCategory = item.verdict?.category
        verdictInterest = item.verdict?.interest
        verdictReason = item.verdict?.reason
        verdictTriagedAt = item.verdict?.triagedAt
        verdictIsUnread = item.verdict?.isUnread ?? true
        verdictTitle = item.verdict?.title
        verdictBody = item.verdict?.body
        macVerdictData = item.macVerdict.flatMap { try? JSONEncoder().encode($0) }
    }

    var item: Inbox.Item {
        var item = Inbox.Item(
            id: id, app: app, fingerprint: fingerprint,
            title: title, subtitle: subtitle, body: body, deliveredAt: deliveredAt
        )
        if let linkURL, let url = URL(string: linkURL) {
            item.link = DeepLinkRecord(
                fingerprint: fingerprint, app: app, url: url, opensExactContent: opensExactContent,
                deliveredAt: deliveredAt, readAt: readAt
            )
        }
        item.recipients = recipients
        item.senderName = senderName
        item.readAt = readAt
        item.chosenCategory = chosenCategory
        item.macVerdict = macVerdictData.flatMap { try? JSONDecoder().decode(MacVerdict.self, from: $0) }
        if let verdictCategory, let verdictTriagedAt {
            item.verdict = VerdictRecord(
                fingerprint: fingerprint, app: app, category: verdictCategory, interest: verdictInterest,
                reason: verdictReason ?? "", triagedAt: verdictTriagedAt, isUnread: verdictIsUnread,
                title: verdictTitle, body: verdictBody, readAt: readAt, subtitle: subtitle, sender: senderName, recipients: recipients
            )
        }
        return item
    }
}

/// The inbox on disk, in Application Support, so a launch shows what the Mac
/// already knows and only asks iCloud for the rest. Kept for a month. Never
/// mirrored to CloudKit: the app has the iCloud entitlement for the links, and
/// SwiftData would otherwise sync this store too.
@MainActor
final class InboxStore {
    nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let container: ModelContainer?
    private var context: ModelContext? { container.map { ModelContext($0) } }

    init() {
        container = Self.makeContainer()
    }

    private static func makeContainer() -> ModelContainer? {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Karui", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = ModelConfiguration(
                "Inbox",
                schema: Schema([InboxEntry.self]),
                url: directory.appending(path: "Inbox.store"),
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: InboxEntry.self, configurations: configuration)
        } catch {
            SafeDiagnosticLog.shared.record("store: unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Everything kept, newest first, after pruning what's older than a month.
    func load(now: Date = Date()) -> [Inbox.Item] {
        guard let context else { return [] }
        let cutoff = now.addingTimeInterval(-Self.retention)
        do {
            try context.delete(model: InboxEntry.self, where: #Predicate { $0.deliveredAt < cutoff })
            let entries = try context.fetch(FetchDescriptor<InboxEntry>(sortBy: [SortDescriptor(\.deliveredAt, order: .reverse)]))
            try context.save()
            SafeDiagnosticLog.shared.record("store: loaded \(entries.count) items")
            return entries.map(\.item)
        } catch {
            SafeDiagnosticLog.shared.record("store: load failed: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ items: [Inbox.Item]) {
        guard let context, !items.isEmpty else { return }
        let ids = items.map(\.id)
        do {
            let existing = try context.fetch(FetchDescriptor<InboxEntry>(predicate: #Predicate { ids.contains($0.id) }))
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for item in items {
                if let entry = byID[item.id] {
                    entry.update(from: item)
                } else {
                    context.insert(InboxEntry(item: item))
                }
            }
            try context.save()
        } catch {
            SafeDiagnosticLog.shared.record("store: save failed: \(error.localizedDescription)")
        }
    }

    func delete(ids: Set<String>) {
        guard let context, !ids.isEmpty else { return }
        let list = Array(ids)
        do {
            try context.delete(model: InboxEntry.self, where: #Predicate { list.contains($0.id) })
            try context.save()
        } catch {
            SafeDiagnosticLog.shared.record("store: delete failed: \(error.localizedDescription)")
        }
    }
}
