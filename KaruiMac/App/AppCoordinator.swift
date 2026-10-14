import AppKit
import KaruiLinkKit

@MainActor
final class AppCoordinator {
    let settings = AppSettings()
    let fullDiskAccess = FullDiskAccess()
    let loginItem = LoginItem()
    let harvestLog = HarvestLog()
    let autoUpdates = AutoUpdateService()
    let sync = DeepLinkSync()
    let syncStatus = SyncStatus()
    private let presence = CompanionPresence()

    private let harvesters = HarvesterRegistry(harvesters: [
        SparkHarvester(),
        SlackHarvester(),
        MessagesHarvester()
    ])
    private let readWatcher = ReadWatcher()
    private var watcher: NotificationDatabaseWatcher?
    private var watchTask: Task<Void, Never>?
    private var readPollTask: Task<Void, Never>?
    /// How often the apps' own data is checked for the items having been read.
    private static let readPollInterval: Duration = .seconds(10)
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        SafeDiagnosticLog.shared.record("app: start")
        fullDiskAccess.refresh()
        startWatchingIfPossible()
        autoUpdates.start()
        let sync = sync
        let syncStatus = syncStatus
        let presence = presence
        Task {
            syncStatus.status = await sync.refreshStatus()
            await sync.deleteExpired()
            if syncStatus.status.isAvailable {
                await presence.start()
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

    private func startWatchingIfPossible() {
        guard fullDiskAccess.isGranted, watcher == nil else { return }
        let watcher = NotificationDatabaseWatcher(
            database: .standard,
            bundleIdentifiers: harvesters.bundleIdentifiers,
            interval: .seconds(1)
        )
        self.watcher = watcher
        let harvesters = harvesters
        let log = harvestLog
        let sync = sync
        let readWatcher = readWatcher
        watchTask = Task {
            for await event in watcher.events() {
                switch event {
                case .appeared(let record):
                    SafeDiagnosticLog.shared.record("watcher: \(record.bundleIdentifier) appeared")
                    guard let harvested = await harvesters.harvest(record) else { continue }
                    let link = harvested.link
                    // Field lengths and the fingerprint's start, to compare with the iPhone's
                    // developer readout when a lookup misses; never the fields themselves.
                    SafeDiagnosticLog.shared.record(
                        "harvest: \(link.app) \(link.opensExactContent ? "exact" : "conversation") · \(link.fingerprint.prefix(12))"
                        + " · title \(record.title?.count ?? 0), subtitle \(record.subtitle?.count ?? 0), body \(record.body?.count ?? 0)"
                    )
                    log.append(link)
                    await sync.send(link)
                    await readWatcher.track(harvested)
                case .disappeared(let id):
                    // Cleared here, or removed by its app once read: seen either way.
                    for harvested in await readWatcher.notificationDisappeared(id: id) {
                        SafeDiagnosticLog.shared.record("read: \(harvested.link.app), notification gone")
                        log.markRead(fingerprint: harvested.link.fingerprint)
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
                    log.markRead(fingerprint: harvested.link.fingerprint)
                    await sync.markRead(fingerprint: harvested.link.fingerprint)
                }
            }
        }
    }
}
