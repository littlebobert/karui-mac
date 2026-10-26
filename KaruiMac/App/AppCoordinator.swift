import AppKit
import KaruiLinkKit

@MainActor
final class AppCoordinator {
    let settings = AppSettings()
    let fullDiskAccess = FullDiskAccess()
    let loginItem = LoginItem()
    let inbox = DemoMode.isActive ? Inbox(defaults: UserDefaults(suiteName: "demo") ?? .standard, store: nil) : Inbox(store: InboxStore())
    let autoUpdates = AutoUpdateService()
    let sync = DeepLinkSync()
    let syncStatus = SyncStatus()
    private let presence = CompanionPresence()
    private let correspondents = CorrespondentSync(
        sources: [SparkCorrespondents(), MessagesCorrespondents()],
        companionIdentifier: CompanionPresence.identifier()
    )

    private let harvesters = HarvesterRegistry(harvesters: [
        SparkHarvester(),
        SlackHarvester(),
        MessagesHarvester()
    ])
    private let readWatcher = ReadWatcher()
    /// For links made from the iPhone's verdicts.
    private let sparkFromVerdicts = SparkHarvester()
    /// The verdicts already looked up in Spark since launch, by fingerprint.
    private var verdictLinkAttempts = Set<String>()
    /// An app may announce an item before it has saved it, so a miss is tried again.
    private static let harvestRetryDelays: [Duration] = [.seconds(10), .seconds(60)]
    private lazy var verdicts = VerdictStore(
        awaiting: { [weak self] in await MainActor.run { self?.inbox.fingerprintsAwaitingVerdict() ?? [] } },
        found: { [weak self] verdicts in
            Task { @MainActor in
                guard let self else { return }
                let added = self.inbox.apply(verdicts)
                self.linkFromVerdicts(verdicts)
                self.noteVerdictsArrived(verdicts)
                self.bannerIfAtMac(added)
                self.repostIfFocused()
                self.banners.remove(ids: self.inbox.items.filter { !$0.isUnread }.map(\.id))
            }
        }
    )
    /// When Sync Now last asked the iPhone, so verdicts arriving soon after count as its answer.
    private var syncRequestedAt: Date?
    private let sortRequests = SortRequests()
    let sortingSettings = SortingSettingsStore()
    private let subscriptions = MacSubscriptions()
    private let presenceReporter = MacPresenceReporter()
    private let banners = MacBanners()
    let setupNudge = SetupNudge()
    private lazy var sorter = MacSorter(settings: sortingSettings)
    /// When the newest verdict from the iPhone was sorted. Recent ones show it sends
    /// its History, which is how its answers to sort requests come back.
    private var newestVerdictAt: Date?
    private var sortRequestTask: Task<Void, Never>?
    /// How often the inbox is checked for notifications to ask the iPhone about.
    private static let sortRequestInterval: Duration = .seconds(60)
    private var watcher: NotificationDatabaseWatcher?
    private var watchTask: Task<Void, Never>?
    private var readPollTask: Task<Void, Never>?
    /// How often the apps' own data is checked for the items having been read.
    private static let readPollInterval: Duration = .seconds(10)
    private var hasStarted = false
    private lazy var inboxWindow = InboxWindowController(coordinator: self)
    private let aboutWindow = AboutWindowController()

    func showAbout() {
        aboutWindow.show()
    }

    var visibleInboxItems: [Inbox.Item] { inbox.visibleItems }

    /// The Dock icon's badge follows the unread count while the setting is on.
    /// Observation re-arms after each change, so this runs for the app's life.
    private func keepDockBadgeCurrent() {
        withObservationTracking {
            let count = settings.showsUnreadBadge ? inbox.unreadCount : 0
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        } onChange: {
            Task { @MainActor [weak self] in self?.keepDockBadgeCurrent() }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        keepDockBadgeCurrent()
        if DemoMode.isActive {
            DemoMode.configure(inbox)
            showInbox()
            if let window = inboxWindow.window {
                window.setContentSize(DemoMode.windowSize)
                window.center()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                if let file = DemoMode.windowFile {
                    try? "\(window.windowNumber)".write(toFile: file, atomically: true, encoding: .utf8)
                }
            }
            return
        }
        SafeDiagnosticLog.shared.record("app: start")
        // A banner opens its notification here, as Mail's does, not in its app.
        banners.open = { [weak self] id, fingerprint in
            guard let self else { return }
            showInbox()
            let item = inbox.item(id: id) ?? fingerprint.flatMap { value in inbox.items.first { $0.fingerprint == value } }
            guard let item else { return }
            inbox.reveal(item.id)
            // Opening it reads it, as a double-click does: with the preview, selecting
            // it reads it too, but open in full nothing else would.
            markRead([item.id])
        }
        banners.start()
        // Read in its own app: Karui's banner for it goes too.
        inbox.onRead = { [weak self] ids in
            self?.banners.remove(ids: Array(ids))
            self?.reposted.subtract(ids)
        }
        refreshSetupNudge()
        // A Focus turning on catches up on the last few minutes' Important ones.
        focusWatcher.changed = { [weak self] _ in self?.repostIfFocused() }
        focusWatcher.start()
        fullDiskAccess.refresh()
        startWatchingIfPossible()
        autoUpdates.start()
        showInbox()
        let sync = sync
        let syncStatus = syncStatus
        let presence = presence
        let correspondents = correspondents
        Task {
            syncStatus.status = await sync.refreshStatus()
            await sync.deleteExpired()
            if syncStatus.status.isAvailable {
                await MainActor.run {
                    self.sortingSettings.start()
                    NSApp.registerForRemoteNotifications()
                    let settings = self.settings
                    self.presenceReporter.isEnabled = { settings.reportsUse }
                    self.presenceReporter.start()
                    // Banners need it, and once asked, the Dock badge needs it too.
                    if settings.reportsUse || settings.showsUnreadBadge { self.banners.requestPermission() }
                }
                await self.subscriptions.ensure()
                await presence.start()
                // Needs Full Disk Access for Messages; Spark's part works without it.
                await correspondents.start()
            }
        }
    }

    func refreshSyncStatus() {
        guard !DemoMode.isActive else { return }
        let sync = sync
        let syncStatus = syncStatus
        Task { syncStatus.status = await sync.refreshStatus() }
    }

    /// Full Disk Access is granted in System Settings, so it's rechecked each time
    /// the person comes back to the app.
    func applicationDidBecomeActive() {
        guard !DemoMode.isActive else { return }
        refreshSetupNudge()
        // A Focus turning on catches up on the last few minutes' Important ones.
        focusWatcher.changed = { [weak self] _ in self?.repostIfFocused() }
        focusWatcher.start()
        fullDiskAccess.refresh()
        startWatchingIfPossible()
    }

    func showInbox() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        inboxWindow.present()
    }

    /// "Karui", or the name of what the inbox has open after it.
    func setInboxWindowTitle(_ title: String) {
        inboxWindow.window?.title = title
    }

    /// Deletes the notification open in full and goes back to the list, which it
    /// has left; Undo brings it back there.
    func deleteOpenItem() {
        guard let id = inbox.openItemID else { return }
        inbox.openItemID = nil
        delete([id])
    }

    func inboxWindowAppeared() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Without a window the app drops out of the Dock when the person prefers that;
    /// it is still running, and the menu bar item or a relaunch brings it back.
    func inboxWindowClosed() {
        guard !settings.showsDockIcon else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Sync Now

    /// Asks the iPhone to send its History and take the Mac's actions now, and
    /// fetches the day's verdicts here right away. The ask is a silent push, which
    /// iOS delivers when it sees fit, so the status line says what has happened.
    func syncNow() {
        guard !DemoMode.isActive else { return }
        inbox.syncNote = L10n.string("Asking your iPhone…")
        let presence = presence
        let verdicts = verdicts
        let sync = sync
        Task {
            let asked = await presence.requestSync()
            await MainActor.run {
                if asked {
                    self.syncRequestedAt = Date()
                    self.inbox.syncNote = L10n.format("Asked the iPhone at %@", Self.timeFormatter.string(from: Date()))
                } else {
                    self.inbox.syncNote = L10n.string("Could not reach iCloud")
                }
            }
            await sync.deleteExpired()
            await verdicts.fetch()
            await self.sortingSettings.refresh()
            await self.askIPhoneToSort()
        }
    }

    // MARK: Pushes

    /// A change on the iPhone, pushed by CloudKit: fetched now, not on the next poll.
    func handleRemoteNotification(_ userInfo: [String: Any]) {
        guard let change = MacSubscriptions.change(in: userInfo) else {
            SafeDiagnosticLog.shared.record("pushes: received one not for Karui's records")
            return
        }
        switch change {
        case .verdict: SafeDiagnosticLog.shared.record("pushes: a verdict changed")
        case .settings: SafeDiagnosticLog.shared.record("pushes: sorting settings changed")
        }
        let verdicts = verdicts
        let sortingSettings = sortingSettings
        Task {
            switch change {
            case .verdict(let recordID): await verdicts.fetch(recordID: recordID)
            case .settings: await sortingSettings.refresh()
            }
        }
    }

    // MARK: Banners

    func badgesAreBlocked() async -> Bool {
        await banners.badgesAreBlocked()
    }

    /// The person turned on quieting the iPhone: this Mac will show banners instead.
    func reportsUseChanged() {
        if settings.reportsUse { banners.requestPermission() }
        presenceReporter.refresh()
    }

    /// While the person is using this Mac the iPhone alerts quietly, so Important
    /// notifications only the iPhone received get a banner here. After a moment, in
    /// case this Mac's own copy arrives and takes the stand-in's place.
    private func bannerIfAtMac(_ ids: [String]) {
        guard settings.reportsUse, presenceReporter.isInUse else { return }
        let fresh = ids.filter { id in
            guard let item = inbox.item(id: id), let verdict = item.verdict else { return false }
            return verdict.category == "notifyNow" && item.isUnread
                && Date().timeIntervalSince(verdict.triagedAt) < MacBanners.freshness
        }
        guard !fresh.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: MacBanners.settleDelay)
            guard let self else { return }
            for id in fresh {
                guard let item = inbox.item(id: id), item.isUnread, item.category == "notifyNow" else { continue }
                banners.post(item)
            }
        }
    }

    /// This Mac's own notifications given a banner during a Focus, by item ID.
    private var reposted = Set<String>()
    private let focusWatcher = MacFocusWatcher()

    /// During a Focus that lets Karui through, this Mac's apps are quiet: their Important
    /// notifications come again as Karui's. Whenever a verdict lands, this Mac's or
    /// the iPhone's, the recent ones are looked at again (`MacRepost`).
    private func repostIfFocused() {
        let now = Date()
        let candidates = inbox.items.filter {
            $0.id.hasPrefix("notification-") && (reposted.contains($0.id) || now.timeIntervalSince($0.deliveredAt) < MacRepost.window)
        }.map(\.id)
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            let focus = await Task.detached { MacFocusFiles.activeFocus() }.value
            // The filter, should macOS run it after all, is a second way to know.
            let isFiltering = MacRepost.isKaruisFocus(focus) ? true : await MacFocusState.isFiltering()
            guard let self else { return }
            for id in candidates {
                guard let item = inbox.item(id: id) else {
                    reposted.remove(id)
                    continue
                }
                switch MacRepost.action(for: item, isFiltering: isFiltering, allowedApps: focus?.allowedApps ?? [], isPosted: reposted.contains(id)) {
                case .post:
                    reposted.insert(id)
                    banners.post(item)
                case .withdraw:
                    reposted.remove(id)
                    banners.remove(ids: [id])
                    SafeDiagnosticLog.shared.record("banners: withdrew one from \(item.app), read or no longer Important")
                case .none:
                    break
                }
            }
            // Past the window, a banner stays as it is.
            reposted = reposted.filter { inbox.item(id: $0).map { Date().timeIntervalSince($0.deliveredAt) < MacRepost.window * 4 } ?? false }
        }
    }

    // MARK: Sorting here

    /// Whether the Second Opinion Shortcut is here, for the inbox's setup step; on
    /// launch and each time the person comes back, as from the Shortcuts app.
    func refreshSetupNudge() {
        let nudge = setupNudge
        let name = settings.secondOpinionShortcutName
        Task { await nudge.refreshShortcut(name: name) }
    }

    var setupStep: SetupNudge.Step? {
        guard !DemoMode.isActive else { return nil }
        return setupNudge.step(settings: settings, sorting: sortingSettings, canSort: canSortHere)
    }

    /// With the iPhone's settings, as the notification arrives.
    private func sortHere(_ itemID: String) {
        guard settings.sortsOnThisMac else { return }
        sorter.sort(itemID: itemID, in: inbox, shortcutName: settings.secondOpinionShortcutName) { [weak self] _ in
            self?.repostIfFocused()
        }
    }

    var canSortHere: Bool { sorter.canSort }

    // MARK: Sorting on the iPhone

    /// Notifications only this Mac received go to the iPhone to sort, when the person has
    /// turned that on and the iPhone is sending its History, the way the answers
    /// come back. Without recent verdicts every notification here would look unsorted.
    private func askIPhoneToSort() async {
        guard settings.asksIPhoneToSort, syncStatus.status.isAvailable,
              let newestVerdictAt, Date().timeIntervalSince(newestVerdictAt) <= VerdictRecord.lifetime else { return }
        let requested = await sortRequests.requested()
        let items = inbox.itemsToSortOnIPhone(excluding: requested)
        guard !items.isEmpty else { return }
        await sortRequests.send(items.prefix(SortRequests.batchLimit).map(SortRequests.Request.init))
    }

    /// Sends a harvested link and watches for the item being read here.
    private func linkUp(_ harvested: HarvestedLink, from record: NotificationRecord) async {
        let link = harvested.link
        // Field lengths and the fingerprint's start, to compare with the iPhone's
        // developer readout when a lookup misses; never the fields themselves.
        SafeDiagnosticLog.shared.record(
            "harvest: \(link.app) \(link.opensExactContent ? "exact" : "conversation") · \(link.fingerprint.prefix(12))"
            + " · title \(record.title?.count ?? 0), subtitle \(record.subtitle?.count ?? 0), body \(record.body?.count ?? 0)"
        )
        inbox.setLink(link, for: record)
        let sent = await sync.send(link)
        if let readAt = sent?.readAt {
            inbox.markRead(fingerprint: link.fingerprint, at: readAt)
        } else {
            await readWatcher.track(harvested)
        }
        relinkMismatched()
    }

    /// A link whose item took the iPhone's fingerprint in a loose match goes again
    /// under that fingerprint, which is what the iPhone looks up.
    private func relinkMismatched() {
        let relinks = inbox.items.compactMap { item -> DeepLinkRecord? in
            guard var link = item.link, link.fingerprint != item.fingerprint else { return nil }
            link.fingerprint = item.fingerprint
            return link
        }
        guard !relinks.isEmpty else { return }
        for link in relinks { inbox.setLink(link) }
        Task { [sync] in
            for link in relinks {
                await sync.send(link)
                SafeDiagnosticLog.shared.record("harvest: \(link.app) link sent again under the iPhone's fingerprint")
            }
        }
    }

    /// Spark can post its notification before the email is in its database, so a
    /// notification that found nothing is looked up again a little later, twice.
    private func retryHarvest(_ record: NotificationRecord) {
        guard let app = KnownApp(macBundleIdentifier: record.bundleIdentifier) else { return }
        let harvesters = harvesters
        let fingerprint = Inbox.fingerprint(for: record, as: app)
        Task { [weak self] in
            for delay in Self.harvestRetryDelays {
                try? await Task.sleep(for: delay)
                // Gone, replaced by another notification, or linked meanwhile.
                guard let self, let item = self.inbox.item(id: Inbox.id(for: record)),
                      item.fingerprint == fingerprint, item.link == nil else { return }
                if let harvested = await harvesters.harvest(record) {
                    SafeDiagnosticLog.shared.record("harvest: found on a retry, after \(delay)")
                    await self.linkUp(harvested, from: record)
                    return
                }
            }
        }
    }

    /// Spark links for the emails the iPhone notified about that have none: ones
    /// this Mac didn't announce, or whose harvest here missed. Spark here has every
    /// email, so the iPhone's subject and time find it. Once per email a launch, for
    /// the day a link lasts. Then any link left under the Mac's fingerprint after a
    /// loose match goes again under the iPhone's.
    private func linkFromVerdicts(_ verdicts: [VerdictRecord], now: Date = Date()) {
        var wanted: [VerdictRecord] = []
        for verdict in verdicts where verdict.deletedAt == nil
            && Inbox.appName(verdict.app) == KnownApp.spark.rawValue
            && now.timeIntervalSince(verdict.triagedAt) < DeepLinkRecord.lifetime
            && verdict.subtitle?.isEmpty == false
            && !verdictLinkAttempts.contains(verdict.fingerprint)
            && !inbox.items.contains(where: { $0.fingerprint == verdict.fingerprint && $0.link != nil }) {
            verdictLinkAttempts.insert(verdict.fingerprint)
            wanted.append(verdict)
        }
        relinkMismatched()
        guard !wanted.isEmpty else { return }
        let spark = sparkFromVerdicts
        Task { [weak self] in
            var found = 0
            for verdict in wanted {
                guard let self,
                      let harvested = spark.harvest(fingerprint: verdict.fingerprint, subject: verdict.subtitle ?? "", near: verdict.triagedAt)
                else { continue }
                found += 1
                self.inbox.setLink(harvested.link)
                let sent = await self.sync.send(harvested.link)
                if let readAt = sent?.readAt {
                    self.inbox.markRead(fingerprint: harvested.link.fingerprint, at: readAt)
                } else if verdict.isUnread, verdict.readAt == nil {
                    await self.readWatcher.track(harvested)
                }
            }
            SafeDiagnosticLog.shared.record("harvest: Spark from the iPhone's verdicts, \(found) of \(wanted.count) found")
        }
    }

    private func noteVerdictsArrived(_ verdicts: [VerdictRecord]) {
        if let newest = verdicts.map(\.triagedAt).max(), newest > newestVerdictAt ?? .distantPast {
            newestVerdictAt = newest
        }
        guard let syncRequestedAt, Date().timeIntervalSince(syncRequestedAt) < 10 * 60 else { return }
        self.syncRequestedAt = nil
        inbox.syncNote = L10n.format("Synced at %@", Self.timeFormatter.string(from: Date()))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: Opening

    /// One level up: the list from an open notification, the groups from an open group.
    func goBack() {
        if inbox.openItemID != nil {
            inbox.openItemID = nil
        } else if inbox.openGroupID != nil {
            inbox.openGroupID = nil
        }
    }

    var canGoBack: Bool { inbox.openItemID != nil || inbox.openGroupID != nil }

    /// Return on a selection: one notification opens, one group opens.
    func openSelection() {
        let selected = inbox.selectedItems
        if selected.count == 1, let item = selected.first { open(item) }
    }

    /// Opens the item where it has somewhere to open, or shows it in full. A
    /// Messages notification without a link still tries its conversation, by the
    /// sender, the way the iPhone does. With the preview pane showing it already,
    /// one with nowhere more exact opens its app instead.
    func open(_ item: Inbox.Item) {
        if let link = item.link {
            NSWorkspace.shared.open(item.app == KnownApp.slack.rawValue ? SlackLink.macURL(for: link.url) : link.url)
            return
        }
        guard item.app == KnownApp.messages.rawValue, !DemoMode.isActive else {
            openWithoutLink(item)
            return
        }
        Task { @MainActor in
            if let url = await MessagesConversationFinder().url(sender: item.sender, subtitle: item.subtitle) {
                SafeDiagnosticLog.shared.record("messages: conversation found by the sender")
                NSWorkspace.shared.open(url)
            } else {
                openWithoutLink(item)
            }
        }
    }

    private func openWithoutLink(_ item: Inbox.Item) {
        if inbox.showsPreview, AppLauncher.canOpen(item.app) {
            AppLauncher.open(item.app)
        } else {
            inbox.openItemID = item.id
        }
    }

    // MARK: Actions on the inbox, applied here at once and sent to the iPhone.

    func markRead(_ ids: Set<String>) {
        let items = inbox.items.filter { ids.contains($0.id) && $0.isUnread }
        guard !items.isEmpty else { return }
        inbox.markRead(ids: ids)
        banners.remove(ids: items.map(\.id))
        let sync = sync
        let verdicts = verdicts
        Task {
            for item in items where item.link != nil {
                await sync.markRead(fingerprint: item.fingerprint)
            }
            await verdicts.apply(.read, to: items.map(\.fingerprint))
        }
    }

    func setCategory(_ category: String, _ ids: Set<String>) {
        let items = inbox.items.filter { ids.contains($0.id) && $0.category != category }
        guard !items.isEmpty else { return }
        inbox.setCategory(category, ids: ids)
        let verdicts = verdicts
        Task { await verdicts.apply(.category(category), to: items.map(\.fingerprint)) }
    }

    /// How long a deletion waits before the iPhone is told, so Undo can take it back whole.
    private static let deleteGracePeriod: Duration = .seconds(5)
    private var pendingDeletes: [UUID: Task<Void, Never>] = [:]

    func delete(_ ids: Set<String>) {
        let removed = inbox.remove(ids: ids)
        guard !removed.isEmpty else { return }
        let token = UUID()
        let verdicts = verdicts
        let fingerprints = removed.map(\.fingerprint)
        pendingDeletes[token] = Task {
            try? await Task.sleep(for: Self.deleteGracePeriod)
            guard !Task.isCancelled else { return }
            await verdicts.apply(.delete, to: fingerprints)
            await MainActor.run { self.pendingDeletes.removeValue(forKey: token) }
        }
        inboxWindow.window?.undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.undoDelete(token: token, removed: removed)
        }
        inboxWindow.window?.undoManager?.setActionName(L10n.string("Delete"))
        let toast = Inbox.Toast(message: L10n.format("%d deleted", removed.count)) { [weak self] in
            self?.inboxWindow.window?.undoManager?.undo()
        }
        inbox.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: Self.deleteGracePeriod)
            if self?.inbox.toast?.id == toast.id { self?.inbox.toast = nil }
        }
    }

    private func undoDelete(token: UUID, removed: [Inbox.Item]) {
        inbox.toast = nil
        inbox.restore(removed)
        if let pending = pendingDeletes.removeValue(forKey: token) {
            // Not yet sent: nothing to take back on iCloud.
            pending.cancel()
        } else {
            let verdicts = verdicts
            Task { await verdicts.apply(.undelete, to: removed.map(\.fingerprint)) }
        }
        inboxWindow.window?.undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.delete(Set(removed.map(\.id)))
        }
    }

    /// While Notification Center's database is missing, the probe runs again every
    /// so often, and the watcher starts the moment macOS has made a new one.
    private var missingDatabaseTask: Task<Void, Never>?

    private func keepLookingForDatabase() {
        guard fullDiskAccess.isDatabaseMissing, missingDatabaseTask == nil else { return }
        missingDatabaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                fullDiskAccess.refresh()
                startWatchingIfPossible()
                if !fullDiskAccess.isDatabaseMissing { break }
            }
            self?.missingDatabaseTask = nil
        }
    }

    private func startWatchingIfPossible() {
        keepLookingForDatabase()
        guard fullDiskAccess.isGranted, watcher == nil else { return }
        let watcher = NotificationDatabaseWatcher(
            database: .standard,
            bundleIdentifiers: harvesters.bundleIdentifiers,
            interval: .seconds(1)
        )
        self.watcher = watcher
        let harvesters = harvesters
        let inbox = inbox
        let sync = sync
        let readWatcher = readWatcher
        let verdicts = verdicts
        Task { await verdicts.start() }
        sortRequestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sortRequestInterval)
                await self?.askIPhoneToSort()
            }
        }
        watchTask = Task {
            for await event in watcher.events() {
                switch event {
                case .appeared(let record), .backfilled(let record):
                    if case .appeared = event {
                        SafeDiagnosticLog.shared.record("watcher: \(record.bundleIdentifier) appeared")
                    }
                    // Shown with or without a link; the verdict is the iPhone's to send.
                    if let app = KnownApp(macBundleIdentifier: record.bundleIdentifier) {
                        let isNew = inbox.add(record, as: app)
                        // New ones only: a launch's backfill would keep the model busy for minutes.
                        if case .appeared = event, isNew { self.sortHere(Inbox.id(for: record)) }
                    }
                    // Kept from before a relaunch: the link is on iCloud already, so
                    // only the read-watch is picked up again, when it's still unread.
                    if case .backfilled = event, let app = KnownApp(macBundleIdentifier: record.bundleIdentifier),
                       let kept = inbox.item(id: Inbox.id(for: record)), kept.link != nil,
                       kept.fingerprint == Inbox.fingerprint(for: record, as: app) {
                        if kept.readAt == nil, let harvested = await harvesters.harvest(record) {
                            await readWatcher.track(harvested)
                        }
                        continue
                    }
                    if let harvested = await harvesters.harvest(record) {
                        await self.linkUp(harvested, from: record)
                    } else if case .appeared = event {
                        self.retryHarvest(record)
                    }
                case .disappeared(let id):
                    // Cleared here, or removed by its app once read: seen either way.
                    for harvested in await readWatcher.notificationDisappeared(id: id) {
                        SafeDiagnosticLog.shared.record("read: \(harvested.link.app), notification gone")
                        inbox.markRead(fingerprint: harvested.link.fingerprint)
                        await sync.markRead(fingerprint: harvested.link.fingerprint)
                    }
                }
            }
        }
        readPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.readPollInterval)
                for harvested in await readWatcher.poll(using: harvesters) {
                    SafeDiagnosticLog.shared.record("read: \(harvested.link.app), in its app")
                    inbox.markRead(fingerprint: harvested.link.fingerprint)
                    await sync.markRead(fingerprint: harvested.link.fingerprint)
                }
            }
        }
    }
}
