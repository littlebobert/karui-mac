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
    private lazy var verdicts = VerdictStore(
        awaiting: { [weak self] in await MainActor.run { self?.inbox.fingerprintsAwaitingVerdict() ?? [] } },
        found: { [weak self] verdicts in
            Task { @MainActor in
                self?.inbox.apply(verdicts)
                self?.noteVerdictsArrived()
            }
        }
    )
    /// When Sync Now last asked the iPhone, so verdicts arriving soon after count as its answer.
    private var syncRequestedAt: Date?
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
        }
    }

    private func noteVerdictsArrived() {
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
    /// sender, the way the iPhone does.
    func open(_ item: Inbox.Item) {
        if let link = item.link {
            NSWorkspace.shared.open(link.url)
            return
        }
        guard item.app == KnownApp.messages.rawValue, !DemoMode.isActive else {
            inbox.openItemID = item.id
            return
        }
        Task { @MainActor in
            if let url = await MessagesConversationFinder().url(sender: item.sender, subtitle: item.subtitle) {
                SafeDiagnosticLog.shared.record("messages: conversation found by the sender")
                NSWorkspace.shared.open(url)
            } else {
                inbox.openItemID = item.id
            }
        }
    }

    // MARK: Actions on the inbox, applied here at once and sent to the iPhone.

    func markRead(_ ids: Set<String>) {
        let items = inbox.items.filter { ids.contains($0.id) && $0.isUnread }
        guard !items.isEmpty else { return }
        inbox.markRead(ids: ids)
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

    private func startWatchingIfPossible() {
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
        watchTask = Task {
            for await event in watcher.events() {
                switch event {
                case .appeared(let record), .backfilled(let record):
                    if case .appeared = event {
                        SafeDiagnosticLog.shared.record("watcher: \(record.bundleIdentifier) appeared")
                    }
                    // Shown with or without a link; the verdict is the iPhone's to send.
                    if let app = KnownApp(macBundleIdentifier: record.bundleIdentifier) {
                        inbox.add(record, as: app)
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
                    guard let harvested = await harvesters.harvest(record) else { continue }
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
