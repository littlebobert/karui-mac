import Foundation
import Security

/// Whether this build may use Karui's iCloud container. A build from source signed
/// by another team can't, and `CKContainer` would crash on it, so the container is
/// never created without the entitlement and the app says it can't send links.
enum CloudKitEntitlement {
    static var hasKaruiContainer: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let identifiers = value as? [String] else {
            return false
        }
        return identifiers.contains(DeepLinkSync.containerIdentifier)
    }
}
