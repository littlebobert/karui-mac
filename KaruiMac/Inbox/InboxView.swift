import KaruiLinkKit
import SwiftUI

struct InboxView: View {
    let coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !coordinator.fullDiskAccess.isGranted {
                FullDiskAccessCard(fullDiskAccess: coordinator.fullDiskAccess)
                    .padding([.horizontal, .top], 16)
            }
            ControlBar(coordinator: coordinator)
            Divider()
            if !coordinator.inbox.selection.isEmpty {
                Text(L10n.format("%d selected", coordinator.inbox.selection.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                Divider()
            }
            InboxList(coordinator: coordinator)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.applicationDidBecomeActive()
        }
    }
}

/// The window's controls, drawn here rather than as a toolbar so they aren't
/// glass. Grouping, density, and search on the left; filters, selection, and the
/// actions on a selection on the right. With a group open, the way back and its
/// name. A right-click offers the display modes a toolbar would.
private struct ControlBar: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var inbox = coordinator.inbox
        HStack(spacing: 12) {
            if let openGroupID = inbox.openGroupID, let group = inbox.group(id: openGroupID) {
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Back"), symbol: "chevron.left") {
                    inbox.openGroupID = nil
                }
                Text(group.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else {
                Picker(L10n.string("View as"), selection: $inbox.grouping) {
                    Text(L10n.string("List")).tag(Inbox.Grouping.none)
                    Text(L10n.string("Apps")).tag(Inbox.Grouping.apps)
                    Text(L10n.string("Senders")).tag(Inbox.Grouping.senders)
                    Text(L10n.string("Threads")).tag(Inbox.Grouping.threads)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            BarButton(mode: inbox.barDisplayMode, label: L10n.string("Compact"), symbol: inbox.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                inbox.isCompact.toggle()
            }
            TextField(L10n.string("Search"), text: $inbox.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer()
            Menu {
                Section(L10n.string("Category")) {
                    categoryToggle("notifyNow", L10n.string("Important"))
                    categoryToggle("summary", L10n.string("Neutral"))
                    categoryToggle("silence", L10n.string("Spam"))
                }
                Section(L10n.string("Read state")) {
                    readToggle(.unread, L10n.string("Unread"))
                    readToggle(.read, L10n.string("Read"))
                }
                Section {
                    Toggle(L10n.string("Only what opens on this Mac"), isOn: $inbox.showsOnlyOpenable)
                }
            } label: {
                BarLabel(mode: inbox.barDisplayMode, label: L10n.string("Filter"), symbol: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.string("Filter"))
            if inbox.selection.isEmpty {
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Select All"), symbol: "checklist") {
                    inbox.selection = Set(inbox.visibleItems.map(\.id))
                }
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Mark All Read"), symbol: "envelope.open") {
                    coordinator.markRead(Set(inbox.visibleItems.map(\.id)))
                }
                .disabled(!inbox.visibleItems.contains { $0.isUnread })
            } else {
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Deselect"), symbol: "xmark.circle") {
                    inbox.selection = []
                }
                Menu {
                    Button(L10n.string("Important")) { coordinator.setCategory("notifyNow", inbox.selection) }
                    Button(L10n.string("Neutral")) { coordinator.setCategory("summary", inbox.selection) }
                    Button(L10n.string("Spam")) { coordinator.setCategory("silence", inbox.selection) }
                    Divider()
                    Button(L10n.string("Read")) { coordinator.markRead(inbox.selection) }
                } label: {
                    BarLabel(mode: inbox.barDisplayMode, label: L10n.string("Mark as"), symbol: "tag")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.string("Mark as"))
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Delete"), symbol: "trash", role: .destructive) {
                    coordinator.delete(inbox.selection)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Picker("", selection: $inbox.barDisplayMode) {
                Text(L10n.string("Icon and Text")).tag(Inbox.BarDisplayMode.iconAndText)
                Text(L10n.string("Icon Only")).tag(Inbox.BarDisplayMode.iconOnly)
                Text(L10n.string("Text Only")).tag(Inbox.BarDisplayMode.textOnly)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var isFiltering: Bool {
        coordinator.inbox.shownCategories.count < Inbox.categories.count
            || coordinator.inbox.shownReadStates.count < Inbox.ReadState.allCases.count
            || coordinator.inbox.showsOnlyOpenable
    }

    private func categoryToggle(_ category: String, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { coordinator.inbox.shownCategories.contains(category) },
            set: { shown in
                if shown { coordinator.inbox.shownCategories.insert(category) } else { coordinator.inbox.shownCategories.remove(category) }
            }
        ))
    }

    private func readToggle(_ state: Inbox.ReadState, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { coordinator.inbox.shownReadStates.contains(state) },
            set: { shown in
                if shown { coordinator.inbox.shownReadStates.insert(state) } else { coordinator.inbox.shownReadStates.remove(state) }
            }
        ))
    }
}

/// A bar button's face in the chosen display mode.
private struct BarLabel: View {
    let mode: Inbox.BarDisplayMode
    let label: String
    let symbol: String

    var body: some View {
        switch mode {
        case .iconAndText:
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.body)
                Text(label).font(.caption2)
            }
        case .iconOnly:
            Image(systemName: symbol).font(.body)
        case .textOnly:
            Text(label)
        }
    }
}

private struct BarButton: View {
    let mode: Inbox.BarDisplayMode
    let label: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            BarLabel(mode: mode, label: label, symbol: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

private struct FullDiskAccessCard: View {
    let fullDiskAccess: FullDiskAccess

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("Full Disk Access is off"))
                    .font(.headline)
                Text(L10n.string("Karui reads Notification Center's database to find where each notification opens. macOS keeps that database behind Full Disk Access and offers no prompt for it: in System Settings, press + under the list, choose Karui, and turn it on."))
                HStack {
                    Button(L10n.string("Open System Settings")) {
                        fullDiskAccess.openSystemSettings()
                    }
                    Button(L10n.string("Show Karui in Finder")) {
                        fullDiskAccess.revealInFinder()
                    }
                    if fullDiskAccess.hasOpenedSystemSettings {
                        Button(L10n.string("Quit and Reopen Karui")) {
                            fullDiskAccess.relaunch()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// The day's notifications with Karui's verdict on each, newest first. Viewed as
/// apps, senders, or threads, the list is of those, and one opens to its
/// notifications.
private struct InboxList: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var inbox = coordinator.inbox
        Group {
            if inbox.items.isEmpty {
                EmptyNote(text: L10n.string("Nothing yet. Notifications from Messages, Spark, and Slack appear here as they arrive on this Mac, with what Karui on your iPhone decided about each."))
            } else if inbox.filtered.isEmpty {
                EmptyNote(text: L10n.string("Nothing matches."))
            } else if let openGroupID = inbox.openGroupID, let group = inbox.group(id: openGroupID) {
                ItemsList(coordinator: coordinator, items: group.items)
            } else if inbox.grouping == .none {
                ItemsList(coordinator: coordinator, items: inbox.filtered)
            } else {
                GroupsList(inbox: inbox, openGroupID: $inbox.openGroupID)
            }
        }
        // A new grouping starts at its own list.
        .onChange(of: inbox.grouping) { _, _ in inbox.openGroupID = nil }
    }
}

private struct EmptyNote: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Apps, senders, or threads: each with how many notifications, how many unread,
/// and the newest's time. Clicking one opens it.
private struct GroupsList: View {
    let inbox: Inbox
    @Binding var openGroupID: String?

    var body: some View {
        List(inbox.groups) { group in
            Button {
                openGroupID = group.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(group.unreadCount > 0 ? Color.accentColor : Color.clear)
                        .frame(width: 8, height: 8)
                    Text(group.title)
                        .fontWeight(group.unreadCount > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    if group.unreadCount > 0 {
                        Text(L10n.format("%d unread", group.unreadCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(group.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(group.newestAt, style: .time)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ItemsList: View {
    let coordinator: AppCoordinator
    let items: [Inbox.Item]

    var body: some View {
        @Bindable var inbox = coordinator.inbox
        List(items, selection: $inbox.selection) { item in
            InboxRow(item: item, isCompact: inbox.isCompact)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let ids = ids.isEmpty ? inbox.selection : ids
            Button(L10n.string("Mark as Read")) { coordinator.markRead(ids) }
            Menu(L10n.string("Mark as")) {
                Button(L10n.string("Important")) { coordinator.setCategory("notifyNow", ids) }
                Button(L10n.string("Neutral")) { coordinator.setCategory("summary", ids) }
                Button(L10n.string("Spam")) { coordinator.setCategory("silence", ids) }
            }
            Divider()
            Button(L10n.string("Delete"), role: .destructive) { coordinator.delete(ids) }
        } primaryAction: { ids in
            // A double-click opens the item where it has somewhere to open, and
            // counts as reading it either way.
            for item in inbox.items where ids.contains(item.id) {
                if let link = item.link { NSWorkspace.shared.open(link.url) }
            }
            coordinator.markRead(ids)
        }
        .onDeleteCommand {
            coordinator.delete(inbox.selection)
        }
    }
}

private struct InboxRow: View {
    let item: Inbox.Item
    let isCompact: Bool

    var body: some View {
        HStack(alignment: isCompact ? .center : .top, spacing: 10) {
            Circle()
                .fill(item.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, isCompact ? 0 : 6)
            if isCompact {
                Text(item.app).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                VerdictBadge(verdict: item.verdict, chosen: item.chosenCategory, isWaiting: item.isWaitingForVerdict).frame(width: 110, alignment: .leading)
                Text(compactLine).lineLimit(1).truncationMode(.tail)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.app).font(.caption).foregroundStyle(.secondary)
                        VerdictBadge(verdict: item.verdict, chosen: item.chosenCategory, isWaiting: item.isWaitingForVerdict)
                    }
                    if let title = item.title, !title.isEmpty {
                        Text(title).fontWeight(.semibold)
                    }
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                    }
                    if let body = item.body, !body.isEmpty {
                        Text(body).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let reason = item.verdict?.reason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if item.readAt != nil {
                        Text(L10n.string("Read here; cleared on the iPhone")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.deliveredAt, format: Calendar.current.isDateInToday(item.deliveredAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
                if !isCompact, let link = item.link {
                    Button(L10n.string("Open")) {
                        NSWorkspace.shared.open(link.url)
                    }
                }
            }
        }
        .padding(.vertical, isCompact ? 1 : 3)
        .tag(item.id)
    }

    private var compactLine: String {
        [item.title, item.subtitle, item.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Karui's category, in its colors; "Sorting…" until the iPhone's verdict arrives.
private struct VerdictBadge: View {
    let verdict: VerdictRecord?
    let chosen: String?
    let isWaiting: Bool

    var body: some View {
        let (label, color): (String, Color) = switch chosen ?? verdict?.category {
        case "notifyNow": (L10n.string("Important"), Color(red: 0.72, green: 0.32, blue: 0.22))
        case "summary": (L10n.string("Neutral"), Color(red: 0.22, green: 0.37, blue: 0.29))
        case "silence": (L10n.string("Spam"), Color.secondary)
        default: (L10n.string(isWaiting ? "Sorting…" : "Not on the iPhone"), Color.secondary)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }
}
