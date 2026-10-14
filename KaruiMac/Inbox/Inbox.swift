import Foundation
import KaruiLinkKit
import Observation

/// The day's notifications from the apps the Mac watches, as Notification Center
/// has them, with what Karui on the iPhone decided about each and the link that
/// opens it; plus, when the person asks for it, the notifications only the iPhone
/// got. In memory; Notification Center and iCloud are the records. Also the
/// window's view state: grouping, filters, search, and selection.
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
        /// A category chosen here, shown until the iPhone's verdict catches up.
        var chosenCategory: String?

        init(id: String, app: String, fingerprint: String, title: String?, subtitle: String?, body: String?, deliveredAt: Date) {
            self.id = id
            self.app = app
            self.fingerprint = fingerprint
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.deliveredAt = deliveredAt
        }

        var category: String? { chosenCategory ?? verdict?.category }
        var isUnread: Bool { readAt == nil && verdict?.isUnread ?? true }

        /// A verdict arrives within a minute or two when the iPhone got the
        /// notification; after this long, it didn't (the app held the push back
        /// while the person was at the Mac, or the phone was off).
        static let verdictWait: TimeInterval = 5 * 60
        var isWaitingForVerdict: Bool {
            verdict == nil && Date().timeIntervalSince(deliveredAt) < Self.verdictWait
        }

        /// Who it's from, for grouping: the title in mail and messaging apps.
        var sender: String { title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        /// The conversation: a subject, a channel, a group chat's name; the sender when there is none.
        var thread: String {
            let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return subtitle.isEmpty ? sender : subtitle
        }

        func matches(_ search: String) -> Bool {
            let haystack = [app, title, subtitle, body, verdict?.reason].compactMap { $0 }.joined(separator: "\n")
            return haystack.localizedCaseInsensitiveContains(search)
        }
    }

    enum Grouping: String, CaseIterable {
        case none, apps, senders, threads
    }

    enum ReadState: String, CaseIterable {
        case unread, read
    }

    /// How the control bar shows its buttons, as a toolbar would.
    enum BarDisplayMode: String, CaseIterable {
        case iconAndText, iconOnly, textOnly
    }

    struct Group: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [Item]

        var unreadCount: Int { items.filter(\.isUnread).count }
        var newestAt: Date { items.map(\.deliveredAt).max() ?? .distantPast }

        static func == (lhs: Group, rhs: Group) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static let categories = ["notifyNow", "summary", "silence"]

    private(set) var items: [Item] = []
    private static let capacity = 3000
    private let defaults: UserDefaults
    private let store: InboxStore?

    // The view's settings, kept across launches.
    var grouping: Grouping { didSet { defaults.set(grouping.rawValue, forKey: "inbox.grouping") } }
    var isCompact: Bool { didSet { defaults.set(isCompact, forKey: "inbox.isCompact") } }
    var shownCategories: Set<String> { didSet { defaults.set(Array(shownCategories).sorted(), forKey: "inbox.shownCategories") } }
    var shownReadStates: Set<ReadState> { didSet { defaults.set(shownReadStates.map(\.rawValue).sorted(), forKey: "inbox.shownReadStates") } }
    var barDisplayMode: BarDisplayMode { didSet { defaults.set(barDisplayMode.rawValue, forKey: "inbox.barDisplayMode") } }
    /// Only what this Mac can open in full: items with a link.
    var showsOnlyOpenable: Bool { didSet { defaults.set(showsOnlyOpenable, forKey: "inbox.showsOnlyOpenable") } }
    var search = ""
    var selection: Set<String> = []
    /// The app, sender, or thread opened from its list; nil at the list.
    var openGroupID: String?
    /// A notification opened in full, when it has nowhere else to open.
    var openItemID: String?

    /// A banner at the bottom of the window with a way to take an action back,
    /// for as long as taking it back is clean.
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: @MainActor () -> Void
    }
    var toast: Toast?

    init(defaults: UserDefaults = .standard, store: InboxStore? = nil) {
        self.defaults = defaults
        self.store = store
        items = store?.load() ?? []
        grouping = defaults.string(forKey: "inbox.grouping").flatMap(Grouping.init(rawValue:)) ?? .none
        isCompact = defaults.bool(forKey: "inbox.isCompact")
        shownCategories = defaults.stringArray(forKey: "inbox.shownCategories").map(Set.init) ?? Set(Inbox.categories)
        shownReadStates = defaults.stringArray(forKey: "inbox.shownReadStates").map { Set($0.compactMap(ReadState.init(rawValue:))) } ?? Set(ReadState.allCases)
        barDisplayMode = defaults.string(forKey: "inbox.barDisplayMode").flatMap(BarDisplayMode.init(rawValue:)) ?? .iconAndText
        showsOnlyOpenable = defaults.bool(forKey: "inbox.showsOnlyOpenable")
    }

    /// The items the toolbar's bulk actions apply to: the open group's, or the filtered day.
    var visibleItems: [Item] {
        if let openGroupID, let group = group(id: openGroupID) { return group.items }
        return filtered
    }

    var filtered: [Item] {
        let search = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            if showsOnlyOpenable, item.link == nil { return false }
            if let category = item.category, !shownCategories.contains(category) { return false }
            if !shownReadStates.contains(item.isUnread ? .unread : .read) { return false }
            return search.isEmpty || item.matches(search)
        }
    }

    func group(id: String) -> Group? { groups.first { $0.id == id } }

    /// The filtered items, grouped as chosen, newest group first.
    var groups: [Group] {
        let items = filtered
        switch grouping {
        case .none:
            return [Group(id: "all", title: "", items: items)]
        case .apps:
            return grouped(items, by: \.app)
        case .senders:
            return grouped(items, by: \.sender)
        case .threads:
            return grouped(items) { "\($0.app) · \($0.thread)" }
        }
    }

    var selectedItems: [Item] { items.filter { selection.contains($0.id) } }

    private func grouped(_ items: [Item], by key: (Item) -> String) -> [Group] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = key(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { Group(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    static func id(for record: NotificationRecord) -> String { "notification-\(record.id)" }

    /// An app with no name is shown as Unknown rather than as nothing.
    static func appName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("Unknown") : trimmed
    }

    func item(id: String) -> Item? { items.first { $0.id == id } }

    /// A notification this Mac got, from Notification Center. Returns whether it was new.
    @discardableResult
    func add(_ record: NotificationRecord, as app: KnownApp) -> Bool {
        let id = Self.id(for: record)
        guard !items.contains(where: { $0.id == id }) else { return false }
        let item = Item(
            id: id,
            app: Self.appName(app.rawValue),
            fingerprint: record.deepLink(as: app, url: URL(string: "about:blank")!, opensExactContent: false).fingerprint,
            title: record.title,
            subtitle: record.subtitle,
            body: record.body,
            deliveredAt: record.deliveredAt ?? Date()
        )
        insert(item)
        store?.save([item])
        return true
    }

    /// The day's verdicts from the iPhone: each goes with its notification here, or,
    /// when it carries the text, stands for a notification only the iPhone got. One
    /// the iPhone has deleted goes.
    func apply(_ verdicts: [VerdictRecord]) {
        var touched = Set<String>()
        for verdict in verdicts {
            if verdict.deletedAt != nil {
                let gone = items.filter { $0.fingerprint == verdict.fingerprint }.map(\.id)
                items.removeAll { $0.fingerprint == verdict.fingerprint }
                store?.delete(ids: Set(gone))
                continue
            }
            if items.contains(where: { $0.fingerprint == verdict.fingerprint }) {
                setVerdict(verdict, for: verdict.fingerprint, persisting: false)
                touched.formUnion(items.filter { $0.fingerprint == verdict.fingerprint }.map(\.id))
            } else if verdict.title != nil || verdict.body != nil {
                var item = Item(
                    id: verdict.fingerprint,
                    app: Self.appName(verdict.app),
                    fingerprint: verdict.fingerprint,
                    title: verdict.title,
                    subtitle: nil,
                    body: verdict.body,
                    deliveredAt: verdict.triagedAt
                )
                item.verdict = verdict
                item.readAt = verdict.readAt
                insert(item)
                touched.insert(item.id)
            }
        }
        persist(touched)
    }

    func setLink(_ link: DeepLinkRecord, for record: NotificationRecord) {
        let id = Self.id(for: record)
        update(id) { $0.link = link; $0.readAt = link.readAt ?? $0.readAt }
        persist([id])
    }

    func markRead(fingerprint: String, at date: Date = Date()) {
        var touched = Set<String>()
        for index in items.indices where items[index].fingerprint == fingerprint {
            items[index].readAt = date
            touched.insert(items[index].id)
        }
        persist(touched)
    }

    func markRead(ids: Set<String>, at date: Date = Date()) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].readAt = date
        }
        persist(ids)
    }

    func setCategory(_ category: String, ids: Set<String>) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].chosenCategory = category
        }
        persist(ids)
    }

    /// The items, removed; for putting back on undo.
    @discardableResult
    func remove(ids: Set<String>) -> [Item] {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        store?.delete(ids: ids)
        return removed
    }

    func restore(_ removed: [Item]) {
        for item in removed { insert(item) }
        store?.save(removed)
    }

    func setVerdict(_ verdict: VerdictRecord, for fingerprint: String, persisting: Bool = true) {
        var touched = Set<String>()
        for index in items.indices where items[index].fingerprint == fingerprint {
            items[index].verdict = verdict
            if items[index].chosenCategory == verdict.category { items[index].chosenCategory = nil }
            if let readAt = verdict.readAt, items[index].readAt == nil { items[index].readAt = readAt }
            touched.insert(items[index].id)
        }
        if persisting { persist(touched) }
    }

    /// The fingerprints still waiting for the iPhone's verdict, among the day's items.
    func fingerprintsAwaitingVerdict(now: Date = Date()) -> [String] {
        items.filter { $0.verdict == nil && now.timeIntervalSince($0.deliveredAt) <= VerdictRecord.lifetime }.map(\.fingerprint)
    }

    private func persist(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        store?.save(items.filter { ids.contains($0.id) })
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

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
