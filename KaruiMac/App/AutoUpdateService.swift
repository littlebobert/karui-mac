import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AutoUpdateService {
    private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        // A debug build run beside the installed app shares its bundle identifier;
        // an automatic update of the build would hold the installer's status service
        // and the installed app's own update fails ("failed to probe status service").
        // Manual checks still work for testing the flow.
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in
                self?.canCheckForUpdates = canCheck
            }
        }
    }

    func checkForUpdates() {
        start()
        SafeDiagnosticLog.shared.record("updater: manual check requested")
        updaterController?.checkForUpdates(nil)
    }
}
