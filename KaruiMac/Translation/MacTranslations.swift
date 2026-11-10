import Foundation
import KaruiSorting

/// Gives the inbox's notifications their translations (`MacTranslator`): each new one
/// as it arrives, before this Mac sorts it, and the last two days' when translation
/// is turned on or a language becomes available. Each item is tried once a launch.
@MainActor
final class MacTranslations {
    /// How long sorting a new notification waits for its translation; one that takes
    /// longer still lands in the inbox when it's done.
    static let arrivalDeadline: Duration = .seconds(5)
    static let recentWindow: TimeInterval = 2 * 24 * 60 * 60
    static let batchLimit = 30

    private let settings: SortingSettingsStore
    private var attempted = Set<String>()
    private var isTranslatingRecent = false

    init(settings: SortingSettingsStore) {
        self.settings = settings
    }

    /// Translates a new notification, then calls `then` once it's done or after
    /// `arrivalDeadline`, whichever comes first; at once when there's nothing to do.
    func translate(_ id: String, in inbox: Inbox, then: @escaping @MainActor () -> Void = {}) {
        guard let work = start(id, in: inbox) else { return then() }
        Task { [weak inbox] in
            let early = await MacTranslator.value(of: work, within: Self.arrivalDeadline)
            if let early { inbox?.setTranslation(early, id: id) }
            then()
            if early == nil, let late = await work.value { inbox?.setTranslation(late, id: id) }
        }
    }

    /// The recent notifications not tried yet, one at a time.
    func translateRecent(in inbox: Inbox) {
        guard !isTranslatingRecent, settings.policy?.translateNotifications == true else { return }
        let since = Date().addingTimeInterval(-Self.recentWindow)
        let ids = inbox.items
            .filter { $0.deliveredAt >= since && $0.translation == nil && !attempted.contains($0.id) }
            .prefix(Self.batchLimit)
            .map(\.id)
        guard !ids.isEmpty else { return }
        isTranslatingRecent = true
        Task { [weak self, weak inbox] in
            defer { self?.isTranslatingRecent = false }
            for id in ids {
                guard let self, let inbox, let work = start(id, in: inbox) else { continue }
                if let translation = await work.value { inbox.setTranslation(translation, id: id) }
            }
        }
    }

    private func start(_ id: String, in inbox: Inbox) -> Task<NotificationTranslation?, Never>? {
        guard #available(macOS 26.4, *), let policy = settings.policy, policy.translateNotifications,
              let item = inbox.item(id: id), item.translation == nil, !attempted.contains(id) else { return nil }
        attempted.insert(id)
        let fields = TranslatableFields(
            title: item.title ?? "",
            subtitle: item.subtitle,
            body: item.body ?? "",
            // On the Mac the title is usually who it's from.
            sender: item.senderName ?? item.title
        )
        return Task { await MacTranslator.translate(fields, policy: policy) }
    }
}
