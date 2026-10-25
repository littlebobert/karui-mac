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
        var id: String
        let app: String
        var fingerprint: String
        var title: String?
        var subtitle: String?
        var body: String?
        var deliveredAt: Date
        /// Who else is in the chat, as the iPhone's Shortcut listed them; from the verdict.
        var recipients: String?
        /// The sender as the Shortcut named them, when the iPhone sent it; History's
        /// Senders view groups by this rather than the title.
        var senderName: String?
        var link: DeepLinkRecord?
        var readAt: Date?
        var verdict: VerdictRecord?
        /// A category chosen here, shown until the iPhone's verdict catches up.
        var chosenCategory: String?
        /// Sorted on this Mac as it arrived (`MacSorter`), shown until the iPhone's
        /// verdict arrives.
        var macVerdict: MacVerdict?

        init(id: String, app: String, fingerprint: String, title: String?, subtitle: String?, body: String?, deliveredAt: Date) {
            self.id = id
            self.app = app
            self.fingerprint = fingerprint
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.deliveredAt = deliveredAt
        }

        var category: String? { chosenCategory ?? verdict?.category ?? macVerdict?.category }
        /// The category as a column sorts it: Important, Neutral, Spam, then none.
        var categoryRank: Int { Inbox.categories.firstIndex(of: category ?? "") ?? Inbox.categories.count }
        /// The subtitle and body on one line, for a compact row; the sender has its own column.
        var compactLine: String {
            [subtitle, body]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        var isUnread: Bool { readAt == nil && verdict?.isUnread ?? true }
        /// Unread and Important: what gets the dot, the counts, and the Dock badge.
        /// Neutral and Spam are read or not, but never wait for the person.
        var needsAttention: Bool { isUnread && category == "notifyNow" }

        /// A verdict usually arrives within a minute when the iPhone got the
        /// notification; after this long, it didn't (the app held the push back
        /// while the person was at the Mac, or the phone was off), and the Mac asks
        /// the iPhone to sort it. The iPhone's log says how long each request took.
        static let verdictWait: TimeInterval = 2 * 60
        var isWaitingForVerdict: Bool {
            verdict == nil && Date().timeIntervalSince(deliveredAt) < Self.verdictWait
        }

        /// Who it's from, for grouping: the title in mail and messaging apps.
        var sender: String {
            let named = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return named.isEmpty ? (title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : named
        }

        /// The thread, the way Karui for iPhone's History groups it: an email thread
        /// by its subject without the "Re:", a workplace channel by its title, a
        /// social post by its text, a chat by the group's name in the subtitle or
        /// else the person in the title. The key folds case and accents; the name
        /// is what's shown.
        var conversation: (key: String, name: String) {
            let app = self.app
            let title = sender
            let subtitle = self.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = self.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch Conversation.kind(of: app) {
            case .email:
                // The iPhone sends subject and body as one text, subject first.
                let subject = Conversation.threadSubject(subtitle.isEmpty ? String(body.prefix { $0 != "\n" }) : subtitle)
                if !subject.isEmpty { return ("\(app)|thread|\(Conversation.normalized(subject))", subject) }
            case .workplace:
                if !title.isEmpty { return ("\(app)|chat|\(Conversation.normalized(title))", title) }
            case .social:
                let post = Conversation.postKey(body)
                if !post.isEmpty {
                    let shown = body.replacingOccurrences(of: "\n", with: " ")
                    return ("\(app)|post|\(post)", shown.count > 60 ? String(shown.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : shown)
                }
                return ("\(app)|app", app)
            case .messaging:
                let people = Conversation.people(in: recipients)
                let name: String
                if !subtitle.isEmpty {
                    name = subtitle
                } else if people.count >= 2 {
                    name = ListFormatter.localizedString(byJoining: Conversation.names(in: recipients))
                } else {
                    name = title
                }
                if people.count >= 2 { return ("\(app)|group|" + people.sorted().joined(separator: ","), name) }
                if !subtitle.isEmpty { return ("\(app)|chat|\(Conversation.normalized(subtitle))", name) }
            }
            if !title.isEmpty { return ("\(app)|chat|\(Conversation.normalized(title))", title) }
            return ("\(app)|app", app)
        }

        /// As the iPhone's search: the notification, who sent it and to whom, and
        /// Karui's reason and search tags.
        func matches(_ search: String) -> Bool {
            let fields = [app, title, subtitle, body, senderName, recipients, verdict?.reason] + (verdict?.tags ?? [])
            let haystack = fields.compactMap { $0 }.joined(separator: "\n")
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
        let app: String
        let items: [Item]

        var count: Int { items.count }
        /// Unread Important ones, as everywhere a count is shown.
        var unreadCount: Int { items.filter(\.needsAttention).count }
        var newestAt: Date { items.map(\.deliveredAt).max() ?? .distantPast }

        static func == (lhs: Group, rhs: Group) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    nonisolated static let categories = ["notifyNow", "summary", "silence"]

    private(set) var items: [Item] = [] { didSet { invalidateCaches() } }
    /// Well above a month of a busy iPhone; the month on disk is the real limit.
    private static let capacity = 20_000
    private let defaults: UserDefaults
    private let store: InboxStore?

    // The view's settings, kept across launches.
    var grouping: Grouping { didSet { defaults.set(grouping.rawValue, forKey: "inbox.grouping") } }
    var isCompact: Bool { didSet { defaults.set(isCompact, forKey: "inbox.isCompact") } }
    /// The selected notification under the list, as in Mail; off unless turned on.
    var showsPreview: Bool { didSet { defaults.set(showsPreview, forKey: "inbox.showsPreview") } }
    var previewHeight: Double { didSet { defaults.set(previewHeight, forKey: "inbox.previewHeight") } }
    var shownCategories: Set<String> { didSet { defaults.set(Array(shownCategories).sorted(), forKey: "inbox.shownCategories"); invalidateCaches() } }
    /// Changing it lets go of what was kept visible: a selection already read when
    /// the Unread filter goes on is hidden with the rest, and leaves the selection,
    /// so the preview doesn't show what the list doesn't.
    var shownReadStates: Set<ReadState> {
        didSet {
            defaults.set(shownReadStates.map(\.rawValue).sorted(), forKey: "inbox.shownReadStates")
            invalidateCaches()
            if !keptVisibleIDs.isEmpty { keptVisibleIDs = [] }
            dropHiddenFromSelection()
        }
    }
    var barDisplayMode: BarDisplayMode { didSet { defaults.set(barDisplayMode.rawValue, forKey: "inbox.barDisplayMode") } }
    /// Only what this Mac can open in full: items with a link.
    var showsOnlyOpenable: Bool { didSet { defaults.set(showsOnlyOpenable, forKey: "inbox.showsOnlyOpenable"); invalidateCaches() } }
    var search = "" { didSet { invalidateCaches() } }
    var selection: Set<String> = []
    /// Set while the filter trims the selection, so the trim isn't taken for the
    /// person selecting: one notification left selected that way isn't read.
    private var isTrimmingSelection = false

    private func dropHiddenFromSelection() {
        guard !selection.isEmpty else { return }
        let shown = selection.intersection(filtered.map(\.id))
        guard shown != selection else { return }
        isTrimmingSelection = true
        selection = shown
    }

    /// Whether the last selection change was the filter's trim, which it then forgets.
    func takeSelectionTrim() -> Bool {
        defer { isTrimmingSelection = false }
        return isTrimmingSelection
    }
    /// Selected while only unread ones are shown: reading them doesn't drop them from
    /// the list until the selection moves on, as in Mail.
    private(set) var keptVisibleIDs: Set<String> = [] { didSet { invalidateCaches() } }

    /// Called as the selection changes, before selecting reads it. Only while read
    /// items are hidden, so the caches survive arrowing through the list otherwise.
    /// What's kept is what's unread as it's selected, and what was kept already; a
    /// read item the filter hid stays hidden though still in the selection.
    func keepVisible(_ ids: Set<String>) {
        let kept: Set<String> = shownReadStates.contains(.read) ? [] : ids.filter { id in
            keptVisibleIDs.contains(id) || item(id: id)?.isUnread == true
        }
        if kept != keptVisibleIDs { keptVisibleIDs = kept }
    }
    /// The columns' sort, newest first until a header is clicked. Kept across
    /// launches as the column's name and direction.
    var sortOrder: [KeyPathComparator<Item>] {
        didSet {
            guard let first = sortOrder.first, let column = Self.sortColumns.first(where: { $0.keyPath == first.keyPath }) else { return }
            defaults.set(column.name, forKey: "inbox.sortColumn")
            defaults.set(first.order == .forward, forKey: "inbox.sortAscending")
        }
    }
    /// The group views' sort, newest first until a header is clicked; kept like the items'.
    var groupSortOrder: [KeyPathComparator<Group>] {
        didSet {
            guard let first = groupSortOrder.first, let column = Self.groupSortColumns.first(where: { $0.keyPath == first.keyPath }) else { return }
            defaults.set(column.name, forKey: "inbox.groupSortColumn")
            defaults.set(first.order == .forward, forKey: "inbox.groupSortAscending")
        }
    }
    private static let groupSortColumns: [(name: String, keyPath: PartialKeyPath<Group>)] = [
        ("name", \.title), ("app", \.app), ("count", \.count), ("unread", \.unreadCount), ("newest", \.newestAt)
    ]
    private static func savedGroupSortOrder(_ defaults: UserDefaults) -> [KeyPathComparator<Group>] {
        let order: SortOrder = defaults.object(forKey: "inbox.groupSortAscending") == nil || defaults.bool(forKey: "inbox.groupSortAscending") ? .forward : .reverse
        switch defaults.string(forKey: "inbox.groupSortColumn") {
        case "name": return [KeyPathComparator(\.title, order: order)]
        case "app": return [KeyPathComparator(\.app, order: order)]
        case "count": return [KeyPathComparator(\.count, order: order)]
        case "unread": return [KeyPathComparator(\.unreadCount, order: order)]
        case "newest": return [KeyPathComparator(\.newestAt, order: order)]
        default: return [KeyPathComparator(\.newestAt, order: .reverse)]
        }
    }

    private static let sortColumns: [(name: String, keyPath: PartialKeyPath<Item>)] = [
        ("app", \.app), ("category", \.categoryRank), ("sender", \.sender), ("notification", \.compactLine), ("time", \.deliveredAt)
    ]
    private static func savedSortOrder(_ defaults: UserDefaults) -> [KeyPathComparator<Item>] {
        let order: SortOrder = defaults.object(forKey: "inbox.sortAscending") == nil || defaults.bool(forKey: "inbox.sortAscending") ? .forward : .reverse
        switch defaults.string(forKey: "inbox.sortColumn") {
        case "app": return [KeyPathComparator(\.app, order: order)]
        case "category": return [KeyPathComparator(\.categoryRank, order: order)]
        case "sender": return [KeyPathComparator(\.sender, order: order)]
        case "notification": return [KeyPathComparator(\.compactLine, order: order)]
        case "time": return [KeyPathComparator(\.deliveredAt, order: order)]
        default: return [KeyPathComparator(\.deliveredAt, order: .reverse)]
        }
    }
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
    /// What Sync Now is up to, for the status line; nil when nothing was asked.
    var syncNote: String?
    /// Bumped by ⌘F; the search field focuses itself when it changes.
    var searchFocusRequest = 0
    /// Bumped by Escape in the search field; the list takes the keyboard back.
    var listFocusRequest = 0

    init(defaults: UserDefaults = .standard, store: InboxStore? = nil) {
        self.defaults = defaults
        self.store = store
        items = (store?.load() ?? []).map { item in
            // A link from another app was attached by a reused record ID (fixed in
            // 0.4.5); such a link is dropped rather than opening the wrong thing.
            guard let link = item.link, !Self.linkFits(link.url, app: item.app) else { return item }
            var cleaned = item
            cleaned.link = nil
            return cleaned
        }
        grouping = defaults.string(forKey: "inbox.grouping").flatMap(Grouping.init(rawValue:)) ?? .none
        isCompact = defaults.bool(forKey: "inbox.isCompact")
        showsPreview = defaults.bool(forKey: "inbox.showsPreview")
        previewHeight = defaults.object(forKey: "inbox.previewHeight") as? Double ?? 220
        shownCategories = defaults.stringArray(forKey: "inbox.shownCategories").map(Set.init) ?? Set(Inbox.categories)
        shownReadStates = defaults.stringArray(forKey: "inbox.shownReadStates").map { Set($0.compactMap(ReadState.init(rawValue:))) } ?? Set(ReadState.allCases)
        barDisplayMode = defaults.string(forKey: "inbox.barDisplayMode").flatMap(BarDisplayMode.init(rawValue:)) ?? .iconAndText
        showsOnlyOpenable = defaults.bool(forKey: "inbox.showsOnlyOpenable")
        sortOrder = Self.savedSortOrder(defaults)
        groupSortOrder = Self.savedGroupSortOrder(defaults)
        // Pairs kept apart before 0.8.11.
        mergeSameLink()
    }

    /// The items the toolbar's bulk actions apply to: the open group's, or the filtered day.
    var visibleItems: [Item] {
        if let openGroupID, let group = group(id: openGroupID) { return group.items }
        return filtered
    }

    // The filtered and sorted lists are kept until something they depend on
    // changes: with thousands of items, recomputing them on every selection change
    // made arrowing through the list lag. The caches are not observed, so reading
    // them doesn't register a dependency; the inputs they're built from are.
    @ObservationIgnored private var filteredCache: [Item]?
    @ObservationIgnored private var sortedCache: (key: String, items: [Item])?
    @ObservationIgnored private var cacheVersion = 0

    private func invalidateCaches() {
        filteredCache = nil
        sortedCache = nil
        cacheVersion &+= 1
    }

    /// Reads every input the caches are built from, so a view that gets a cached
    /// list still depends on them. Otherwise only the first view to read after a
    /// change registers the inputs, and the next keystroke in Search updates the
    /// count in the status line but not the table.
    private func noteCacheInputs() {
        _ = items.count
        _ = search
        _ = showsOnlyOpenable
        _ = shownCategories
        _ = shownReadStates
        _ = keptVisibleIDs
    }

    var filtered: [Item] {
        noteCacheInputs()
        if let filteredCache { return filteredCache }
        let search = search.trimmingCharacters(in: .whitespaces)
        let result = items.filter { item in
            if showsOnlyOpenable, item.link == nil { return false }
            if let category = item.category, !shownCategories.contains(category) { return false }
            if !shownReadStates.contains(item.isUnread ? .unread : .read), !keptVisibleIDs.contains(item.id) { return false }
            return search.isEmpty || item.matches(search)
        }
        filteredCache = result
        return result
    }

    /// The items the list shows, in the columns' order: the open group's, or the
    /// filtered day. Sorted once per change of items, filters, group, or sort.
    var sortedVisibleItems: [Item] {
        noteCacheInputs()
        let key = "\(cacheVersion)|\(openGroupID ?? "")|\(grouping.rawValue)|" + sortOrder.map { "\($0.keyPath)\($0.order)" }.joined()
        if let sortedCache, sortedCache.key == key { return sortedCache.items }
        let result = visibleItems.sorted(using: sortOrder)
        sortedCache = (key, result)
        return result
    }

    func group(id: String) -> Group? { groups.first { $0.id == id } }

    /// The filtered items, grouped as chosen, newest group first.
    var groups: [Group] {
        let items = filtered
        switch grouping {
        case .none:
            return [Group(id: "all", title: "", app: "", items: items)]
        case .apps:
            return grouped(items) { ($0.app, $0.app) }
        case .senders:
            return grouped(items) { ("\($0.app)|sender|\(Conversation.normalized($0.sender))", $0.sender) }
        case .threads:
            return grouped(items) { let c = $0.conversation; return (c.key, c.name) }
        }
    }

    var selectedItems: [Item] { items.filter { selection.contains($0.id) } }

    /// Whether every one of these items already has the category: nothing to mark.
    func allHaveCategory(_ category: String, ids: Set<String>) -> Bool {
        let chosen = items.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { $0.category == category }
    }

    private func grouped(_ items: [Item], by key: (Item) -> (key: String, name: String)) -> [Group] {
        var order: [String] = []
        var names: [String: String] = [:]
        var buckets: [String: [Item]] = [:]
        for item in items {
            let (key, name) = key(item)
            if buckets[key] == nil { order.append(key); names[key] = name }
            buckets[key, default: []].append(item)
        }
        return order.map { Group(id: $0, title: names[$0] ?? $0, app: buckets[$0]?.first?.app ?? "", items: buckets[$0] ?? []) }
    }

    static func id(for record: NotificationRecord) -> String { "notification-\(record.id)" }

    /// Whether a saved link is one this app's harvester makes. Slack's permalinks are
    /// `https`; until 0.7.9 they failed this at every launch and were dropped, so a
    /// Slack item opened only Slack itself.
    static func linkFits(_ url: URL, app: String) -> Bool {
        guard let app = KnownApp(rawValue: app), let scheme = url.scheme?.lowercased() else { return true }
        return app.linkSchemes.contains(scheme)
    }

    /// An app with no name is shown as Unknown rather than as nothing.
    static func appName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("Unknown") : trimmed
    }

    func item(id: String) -> Item? { items.first { $0.id == id } }

    /// Unread Important across everything held, whatever the filters show.
    var unreadCount: Int { items.filter(\.needsAttention).count }

    /// Everything at once, for the demo; nothing is written to disk.
    func replaceItems(_ newItems: [Item]) {
        items = newItems
        selection = []
        openGroupID = nil
        openItemID = nil
    }

    /// The same notification seen by both devices can hash differently; when the
    /// fingerprint doesn't match, `LooseMatch` says whether it's the same one.
    static let looseMatchWindow = LooseMatch.window

    /// A verdict goes with an item of its fingerprint delivered this close to when
    /// the iPhone sorted it. The fingerprint is the app, sender, and text, so "Hi"
    /// from the same person on two days is one fingerprint; the verdict sorted today
    /// belongs to today's notification, not the one from three days ago.
    static let verdictMatchWindow: TimeInterval = 60 * 60

    private func indices(matching verdict: VerdictRecord) -> [Int] {
        items.indices.filter {
            items[$0].fingerprint == verdict.fingerprint
                && abs(items[$0].deliveredAt.timeIntervalSince(verdict.triagedAt)) <= Self.verdictMatchWindow
        }
    }

    static func looselyMatches(_ item: Item, app: String, title: String?, subtitle: String? = nil, body: String?, at date: Date) -> Bool {
        guard item.app == appName(app), abs(item.deliveredAt.timeIntervalSince(date)) <= looseMatchWindow else { return false }
        return LooseMatch.sameNotification(
            app: item.app,
            LooseMatch.Fields(title: item.title, subtitle: item.subtitle, body: item.body),
            LooseMatch.Fields(title: title, subtitle: subtitle, body: body)
        )
    }

    static func fingerprint(for record: NotificationRecord, as app: KnownApp) -> String {
        record.deepLink(as: app, url: URL(string: "about:blank")!, opensExactContent: false).fingerprint
    }

    /// A notification this Mac received, from Notification Center. Returns whether it was new.
    ///
    /// Notification Center reuses a cleared notification's record ID for the next
    /// one, so an item with this ID may be an older notification; it is kept under
    /// another ID and the new one takes its place.
    @discardableResult
    func add(_ record: NotificationRecord, as app: KnownApp) -> Bool {
        let id = Self.id(for: record)
        let fingerprint = Self.fingerprint(for: record, as: app)
        if let index = items.firstIndex(where: { $0.id == id }) {
            // The same notification again, as when the harvest catches up. One with the
            // same fingerprint that arrived at another time is a new one under a reused
            // ID: a bot's posts can match for as much of the text as the fingerprint keeps.
            let isSame = items[index].fingerprint == fingerprint
                && abs(items[index].deliveredAt.timeIntervalSince(record.deliveredAt ?? items[index].deliveredAt)) <= 60
            guard !isSame else { return false }
            let stale = items[index]
            var rekeyed = stale
            rekeyed.id = "\(id)-\(stale.fingerprint.prefix(12))"
            items[index] = rekeyed
            store?.delete(ids: [id])
            store?.save([rekeyed])
            SafeDiagnosticLog.shared.record("inbox: record id reused, kept the earlier notification")
        }
        // The iPhone's verdict may have arrived first and stand in for this
        // notification as a text-only item; it becomes this one, keeping its verdict.
        // Only a stand-in, and only one from about now: the fingerprint keeps the start
        // of the text, so yesterday's post from the same bot can share it.
        let deliveredAt = record.deliveredAt ?? Date()
        if let index = items.firstIndex(where: {
            $0.fingerprint == fingerprint && $0.id != id && !$0.id.hasPrefix("notification-")
                && abs($0.deliveredAt.timeIntervalSince(deliveredAt)) <= Self.verdictMatchWindow
        })
            ?? items.firstIndex(where: { !$0.id.hasPrefix("notification-")
                                         && Self.looselyMatches($0, app: app.rawValue, title: record.title, subtitle: record.subtitle, body: record.body, at: record.deliveredAt ?? Date()) }) {
            let standIn = items[index]
            var merged = standIn
            merged.id = id
            merged.title = record.title
            merged.subtitle = record.subtitle
            merged.body = record.body
            merged.deliveredAt = record.deliveredAt ?? standIn.deliveredAt
            items[index] = merged
            store?.delete(ids: [standIn.id])
            store?.save([merged])
            return true
        }
        let item = Item(
            id: id,
            app: Self.appName(app.rawValue),
            fingerprint: fingerprint,
            title: record.title,
            subtitle: record.subtitle,
            body: record.body,
            deliveredAt: record.deliveredAt ?? Date()
        )
        insert(item)
        store?.save([item])
        return true
    }

    /// A verdict that says unread, over one that said read, stays read. An iPhone and
    /// an iPad write the same record, the last one wins, and a device that was off
    /// while the person read things sends them unread when it comes back. Marking one
    /// unread again on the iPhone doesn't reach the Mac, which is the smaller loss.
    static func keepingRead(_ verdict: VerdictRecord, over previous: VerdictRecord?) -> VerdictRecord {
        guard verdict.isUnread, previous?.isUnread == false else { return verdict }
        var kept = verdict
        kept.isUnread = false
        return kept
    }

    /// The day's verdicts from the iPhone: each goes with its notification here, or,
    /// when it carries the text, stands for a notification only the iPhone got. One
    /// the iPhone has deleted goes. Returns the IDs of notifications only the iPhone
    /// got that are new here.
    @discardableResult
    func apply(_ verdicts: [VerdictRecord]) -> [String] {
        var touched = Set<String>()
        var added: [String] = []
        for verdict in verdicts {
            if verdict.deletedAt != nil {
                let gone = Set(indices(matching: verdict).map { items[$0].id })
                items.removeAll { gone.contains($0.id) }
                store?.delete(ids: gone)
                continue
            }
            var matching = indices(matching: verdict)
            // An earlier pass kept the iPhone's copy apart from the Mac's own, which
            // has the link (as Slack's thread replies were): the Mac's takes over.
            var carriedReadAt: Date?
            if !matching.isEmpty, matching.allSatisfy({ !items[$0].id.hasPrefix("notification-") }),
               items.contains(where: { $0.verdict == nil && $0.id.hasPrefix("notification-")
                                       && Self.looselyMatches($0, app: verdict.app, title: verdict.title, subtitle: verdict.subtitle, body: verdict.body, at: verdict.triagedAt) }) {
                let duplicates = Set(matching.map { items[$0].id })
                carriedReadAt = matching.compactMap { items[$0].readAt }.max()
                items.removeAll { duplicates.contains($0.id) }
                store?.delete(ids: duplicates)
                selection.subtract(duplicates)
                matching = []
                SafeDiagnosticLog.shared.record("verdicts: merged \(duplicates.count) copy into the Mac's own")
            }
            if !matching.isEmpty {
                for index in matching {
                    items[index].verdict = Self.keepingRead(verdict, over: items[index].verdict)
                    if items[index].recipients == nil { items[index].recipients = verdict.recipients }
                    if items[index].senderName == nil { items[index].senderName = verdict.sender }
                    if items[index].chosenCategory == verdict.category { items[index].chosenCategory = nil }
                    if let readAt = verdict.readAt, items[index].readAt == nil { items[index].readAt = readAt }
                    touched.insert(items[index].id)
                }
            } else if let index = items.firstIndex(where: { $0.verdict == nil && $0.id.hasPrefix("notification-")
                                                       && Self.looselyMatches($0, app: verdict.app, title: verdict.title, subtitle: verdict.subtitle, body: verdict.body, at: verdict.triagedAt) }) {
                // The Mac's copy takes the iPhone's fingerprint, so what's done to it
                // here reaches the iPhone's record.
                items[index].fingerprint = verdict.fingerprint
                items[index].verdict = verdict
                if items[index].readAt == nil { items[index].readAt = verdict.readAt ?? carriedReadAt }
                if items[index].recipients == nil { items[index].recipients = verdict.recipients }
                if items[index].senderName == nil { items[index].senderName = verdict.sender }
                touched.insert(items[index].id)
                SafeDiagnosticLog.shared.record("verdicts: matched one loosely, by sender and text")
            } else if verdict.title != nil || verdict.body != nil {
                // An earlier notification with the same text keeps its own row; this
                // one's ID carries the time, so the two stay apart.
                let isRepeat = items.contains { $0.fingerprint == verdict.fingerprint }
                var item = Item(
                    id: isRepeat ? "\(verdict.fingerprint)@\(Int(verdict.triagedAt.timeIntervalSince1970))" : verdict.fingerprint,
                    app: Self.appName(verdict.app),
                    fingerprint: verdict.fingerprint,
                    title: verdict.title,
                    subtitle: verdict.subtitle,
                    body: verdict.body,
                    deliveredAt: verdict.triagedAt
                )
                item.recipients = verdict.recipients
                item.senderName = verdict.sender
                item.verdict = verdict
                item.readAt = verdict.readAt
                insert(item)
                touched.insert(item.id)
                added.append(item.id)
            }
        }
        persist(touched)
        return added
    }

    /// The link goes with the notification it was harvested from, matched by
    /// fingerprint, never by record ID alone (see `add`).
    func setLink(_ link: DeepLinkRecord, for record: NotificationRecord) {
        let id = Self.id(for: record)
        // Or the notification itself, when it has taken the iPhone's fingerprint; the
        // link then goes again under that one (`AppCoordinator.relinkMismatched`).
        guard let index = items.firstIndex(where: { $0.id == id && $0.fingerprint == link.fingerprint })
            ?? items.firstIndex(where: { $0.fingerprint == link.fingerprint })
            ?? items.firstIndex(where: { $0.id == id }) else { return }
        items[index].link = link
        items[index].readAt = link.readAt ?? items[index].readAt
        persist([items[index].id])
        mergeSameLink()
    }

    /// A link made from the iPhone's verdict, or sent again under its fingerprint:
    /// for every item of that fingerprint.
    func setLink(_ link: DeepLinkRecord) {
        var touched = Set<String>()
        for index in items.indices where items[index].fingerprint == link.fingerprint {
            items[index].link = link
            touched.insert(items[index].id)
        }
        persist(touched)
        mergeSameLink()
    }

    /// Apps whose link names one email (Spark: its message ID) or one post (Slack:
    /// its timestamp). A Messages link opens the conversation, which two messages
    /// from the same person share.
    static let linksNameOneItem: Set<KnownApp> = [.spark, .slack]

    /// An iPhone stand-in and the Mac's own copy whose links open the same email or
    /// message are one notification, however differently each device cut its text:
    /// Spark for Mac can repeat an email's first line, so `LooseMatch` kept them
    /// apart until the link made from the verdict found the same email. The Mac's
    /// copy takes the stand-in's fingerprint, verdict, and link, so what's done to it
    /// here reaches the iPhone's record, and the stand-in goes.
    func mergeSameLink() {
        func namesOne(_ item: Item) -> DeepLinkRecord? {
            guard let link = item.link, link.opensExactContent,
                  let app = KnownApp(rawValue: item.app), Self.linksNameOneItem.contains(app) else { return nil }
            return link
        }
        var macCopies: [URL: [Int]] = [:]
        for index in items.indices where items[index].id.hasPrefix("notification-") && items[index].verdict == nil {
            guard let link = namesOne(items[index]) else { continue }
            macCopies[link.url, default: []].append(index)
        }
        guard !macCopies.isEmpty else { return }
        var merged: [String: String] = [:]
        for standIn in items where !standIn.id.hasPrefix("notification-") {
            guard let link = namesOne(standIn),
                  let index = macCopies[link.url]?.first(where: { items[$0].app == standIn.app
                      && items[$0].verdict == nil
                      && abs(items[$0].deliveredAt.timeIntervalSince(standIn.deliveredAt)) <= Self.looseMatchWindow })
            else { continue }
            var copy = items[index]
            copy.fingerprint = standIn.fingerprint
            copy.verdict = standIn.verdict
            copy.link = link
            copy.readAt = [copy.readAt, standIn.readAt].compactMap { $0 }.min()
            if copy.recipients == nil { copy.recipients = standIn.recipients }
            if copy.senderName == nil { copy.senderName = standIn.senderName }
            if copy.chosenCategory == nil { copy.chosenCategory = standIn.chosenCategory }
            if copy.chosenCategory == copy.verdict?.category { copy.chosenCategory = nil }
            items[index] = copy
            merged[standIn.id] = copy.id
        }
        guard !merged.isEmpty else { return }
        let standIns = Set(merged.keys)
        items.removeAll { standIns.contains($0.id) }
        store?.delete(ids: standIns)
        persist(Set(merged.values))
        // Selected or open, the stand-in is so as the Mac's copy.
        if !selection.isDisjoint(with: standIns) {
            selection = Set(selection.map { merged[$0] ?? $0 })
        }
        if let open = openItemID, let copy = merged[open] { openItemID = copy }
        SafeDiagnosticLog.shared.record("verdicts: merged \(merged.count) copy into the Mac's own, by link")
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

    func setMacVerdict(_ verdict: MacVerdict, id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].macVerdict = verdict
        persist([id])
    }

    func setVerdict(_ verdict: VerdictRecord, for fingerprint: String, persisting: Bool = true) {
        var touched = Set<String>()
        for index in items.indices where items[index].fingerprint == fingerprint {
            items[index].verdict = verdict
            if items[index].recipients == nil { items[index].recipients = verdict.recipients }
            if items[index].senderName == nil { items[index].senderName = verdict.sender }
            if items[index].chosenCategory == verdict.category { items[index].chosenCategory = nil }
            if let readAt = verdict.readAt, items[index].readAt == nil { items[index].readAt = readAt }
            touched.insert(items[index].id)
        }
        if persisting { persist(touched) }
    }

    /// Notifications this Mac received that the iPhone still hasn't sorted after the
    /// wait for its verdict: the ones to ask it about (`SortRequests`). Not those the
    /// person sorted here, those already asked about, or ones with no text.
    func itemsToSortOnIPhone(now: Date = Date(), excluding requested: Set<String>) -> [Item] {
        items.filter { item in
            let age = now.timeIntervalSince(item.deliveredAt)
            return item.id.hasPrefix("notification-")
                && item.verdict == nil
                && item.chosenCategory == nil
                && !requested.contains(item.fingerprint)
                && age >= Item.verdictWait
                && age <= SortRequests.reach
                && [item.title, item.subtitle, item.body].contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        }
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

/// How an app's notifications name a conversation; the same rules as Karui for
/// iPhone's `ConversationCooldown`, by the app's display name.
enum Conversation {
    enum Kind { case messaging, email, workplace, social }

    static func kind(of app: String) -> Kind {
        let key = normalized(app)
        if ["mail", "gmail", "outlook", "spark", "メール"].contains(key) { return .email }
        if ["slack", "microsoft teams", "discord", "chatwork"].contains(key) { return .workplace }
        if key == "x" { return .social }
        return .messaging
    }

    /// A post's opening, enough to tell posts apart, folded for matching.
    static func postKey(_ body: String) -> String {
        String(normalized(body.replacingOccurrences(of: "\n", with: " ")).prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// An email thread's subject without the reply and forward prefixes that vary
    /// along it: "Re: Re: Q3 budget" and "Fwd: Q3 budget" are one thread.
    static func threadSubject(_ subject: String) -> String {
        var subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = try! NSRegularExpression(
            pattern: "^(re|fw|fwd|aw|sv|tr|wg|回复|答复|返信|転送|답장|전달)(\\s*\\[\\d+\\])?\\s*[:：]\\s*",
            options: [.caseInsensitive]
        )
        while let match = prefix.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range, in: subject) {
            subject = String(subject[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return subject
    }

    static func normalized(_ value: some StringProtocol) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The people a notification lists as recipients, as the iPhone's Shortcut gives
    /// them: names separated by commas, semicolons, newlines, or 、.
    static func names(in recipients: String?) -> [String] {
        (recipients ?? "")
            .split(whereSeparator: { [",", "\n", ";", "、"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func people(in recipients: String?) -> Set<String> {
        Set(names(in: recipients).map(normalized))
    }
}
