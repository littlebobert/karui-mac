import Foundation
import Observation

/// iCloud's state as last checked, for Settings.
@MainActor
@Observable
final class SyncStatus {
    var status: DeepLinkSync.Status = .unknown

    var description: String {
        switch status {
        case .unknown: L10n.string("Checking…")
        case .available: L10n.string("Sending links to your iPhone")
        case .noAccount: L10n.string("Sign in to iCloud on this Mac to send links to your iPhone")
        case .restricted: L10n.string("iCloud is restricted on this Mac")
        case .unavailable(let reason): reason
        }
    }
}
