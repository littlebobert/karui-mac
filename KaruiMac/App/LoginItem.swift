import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            SafeDiagnosticLog.shared.record("login item: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
