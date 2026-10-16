import Foundation
import KaruiLinkKit
import KaruiSorting

/// Where this Mac keeps the iPhone's sorting settings and learned corrections.
enum MacSortingFiles {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Karui", directoryHint: .isDirectory)
    }
    static var policy: URL { folder.appending(path: "SortingSettings.json") }
    static var corrections: URL { folder.appending(path: "CorrectionMemory.json") }
}

/// The people the person has written to, as hashes, from this Mac's own mail and
/// Messages (`CorrespondentSync`), for the rule the iPhone applies with the same list.
final class KnownCorrespondentHashes: @unchecked Sendable {
    static let shared = KnownCorrespondentHashes()
    private let lock = NSLock()
    private var hashes: Set<String> = []

    func replace(with hashes: Set<String>) {
        lock.withLock { self.hashes = hashes }
    }

    /// As the iPhone matches: mail apps put the sender in the title, messaging apps in Sender.
    func match(for notification: NotificationInput) -> String? {
        let hashes = lock.withLock { self.hashes }
        guard !hashes.isEmpty else { return nil }
        for candidate in [notification.sender, notification.title] {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty,
                  let hash = CorrespondentHash.make(candidate), hashes.contains(hash) else { continue }
            return candidate
        }
        return nil
    }
}

extension SortingEnvironment {
    /// The Mac has no calendar context to give, and its model isn't rationed the way
    /// an iPhone app's is in the background, so the log line says only that it's a Mac.
    static let mac = SortingEnvironment(
        calendarContext: { _ in "No calendar context is available." },
        correspondentMatch: { KnownCorrespondentHashes.shared.match(for: $0) },
        applyingCorrections: { CorrectionMemory.applying(to: $0, for: $1, policy: $2, fileURL: MacSortingFiles.corrections) },
        conditions: { ("Mac", "thermal \(ProcessInfo.processInfo.thermalState.rawValue)") }
    )
}
