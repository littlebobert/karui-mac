import AppKit
import KaruiLinkKit

@MainActor
final class AppCoordinator {
    let settings = AppSettings()
    let fullDiskAccess = FullDiskAccess()
    let loginItem = LoginItem()
    let inbox = Inbox(store: InboxStore())
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
            Task { @MainActor in self?.inbox.apply(verdicts) }
        }
    )
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

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
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
        let sync = sync
        let syncStatus = syncStatus
        Task { syncStatus.status = await sync.refreshStatus() }
    }

    /// Full Disk Access is granted in System Settings, so it's rechecked each time
    /// the person comes back to the app.
    func applicationDidBecomeActive() {
        fullDiskAccess.refresh()
        startWatchingIfPossible()
    }

    func showInbox() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        inboxWindow.present()
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

    func delete(_ ids: Set<String>) {
        let items = inbox.items.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        inbox.remove(ids: ids)
        let verdicts = verdicts
        Task { await verdicts.apply(.delete, to: items.map(\.fingerprint)) }
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
                    if case .backfilled = event, let kept = inbox.item(id: Inbox.id(for: record)), kept.link != nil {
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
