import Foundation
import KaruiLinkKit
import Observation

/// The links found since launch, newest first, for the window. In memory only.
@MainActor
@Observable
final class HarvestLog {
    struct Entry: Identifiable {
        let id = UUID()
        let link: DeepLinkRecord
        var readAt: Date?
    }

    private(set) var entries: [Entry] = []
    private static let capacity = 200

    func markRead(fingerprint: String, at date: Date = Date()) {
        for index in entries.indices where entries[index].link.fingerprint == fingerprint {
            entries[index].readAt = date
        }
    }

    func append(_ link: DeepLinkRecord) {
        entries.insert(Entry(link: link), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }
}
