import KaruiLinkKit
import SwiftUI

struct InboxView: View {
    let coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !coordinator.fullDiskAccess.isGranted && !DemoMode.isActive {
                FullDiskAccessCard(fullDiskAccess: coordinator.fullDiskAccess)
                    .padding([.horizontal, .top], 16)
            }
            if let openItemID = coordinator.inbox.openItemID, let item = coordinator.inbox.item(id: openItemID) {
                // One notification in full: its own bar, with nothing that belongs to a list.
                DetailBar(coordinator: coordinator, item: item)
                Divider()
                ItemDetail(item: item, onBack: { coordinator.inbox.openItemID = nil }, onDelete: { coordinator.deleteOpenItem() })
            } else {
                ControlBar(coordinator: coordinator)
                Divider()
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                Divider()
                InboxList(coordinator: coordinator)
            }
        }
        .onChange(of: windowTitle, initial: true) { _, title in
            coordinator.setInboxWindowTitle(title)
        }
        // Selecting one notification reads it, as in Mail. A multiple selection
        // doesn't, so Select All stays a way to act on many without reading them.
        .onChange(of: coordinator.inbox.selection) { _, selection in
            if selection.count == 1, let id = selection.first {
                coordinator.markRead([id])
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = coordinator.inbox.toast {
                HStack(spacing: 12) {
                    Text(toast.message)
                    Button(L10n.string("Undo")) { toast.undo() }
                        .buttonStyle(.link)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.inbox.toast?.id)
        // Larger type in the site's screenshots, which are shown smaller than life.
        .dynamicTypeSize(DemoMode.isActive ? .xLarge : .large)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.applicationDidBecomeActive()
        }
    }

    /// "Karui", or "Karui: " and the name of what is open, in the title bar.
    private var windowTitle: String {
        let inbox = coordinator.inbox
        if let openItemID = inbox.openItemID, let item = inbox.item(id: openItemID) {
            return "Karui: " + (item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.app)
        }
        if let openGroupID = inbox.openGroupID, let group = inbox.group(id: openGroupID) {
            return "Karui: " + group.title
        }
        return "Karui"
    }

    /// The selection when there is one; otherwise what the list holds, and how
    /// many of them are unread.
    private var statusLine: String {
        let inbox = coordinator.inbox
        let line: String
        if !inbox.selection.isEmpty {
            line = L10n.format("%d selected", inbox.selection.count)
        } else {
            let shown = inbox.visibleItems
            let unread = shown.filter(\.isUnread).count
            let count = L10n.format("%d notifications", shown.count)
            line = unread == 0 ? count : count + " · " + L10n.format("%d unread", unread)
        }
        return inbox.syncNote.map { line + " · " + $0 } ?? line
    }
}

/// The window's controls, drawn here rather than as a toolbar so they aren't
/// glass. Grouping, density, and search on the left; filters, selection, and the
/// actions on a selection on the right. With a group open, the way back. A
/// right-click offers the display modes a toolbar would.
private struct ControlBar: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var inbox = coordinator.inbox
        HStack(spacing: 12) {
            if inbox.openGroupID != nil {
                // The group's name is in the title bar.
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Back"), symbol: "chevron.left") {
                    inbox.openGroupID = nil
                }
            } else {
                BarMenuButton(mode: inbox.barDisplayMode, label: L10n.string("View as"), symbol: groupingSymbol) {
                    [(L10n.string("List"), Inbox.Grouping.none), (L10n.string("Apps"), .apps), (L10n.string("Senders"), .senders), (L10n.string("Threads"), .threads)]
                        .map { title, grouping in .item(title, isOn: inbox.grouping == grouping) { inbox.grouping = grouping } }
                }
            }
            BarButton(mode: inbox.barDisplayMode, label: L10n.string(inbox.isCompact ? "Expanded" : "Compact"), symbol: inbox.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                inbox.isCompact.toggle()
            }
            TextField(L10n.string("Search"), text: $inbox.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer()
            BarMenuButton(mode: inbox.barDisplayMode, label: L10n.string("Filter"), symbol: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                [
                    .header(L10n.string("Category")),
                    categoryToggle("notifyNow", L10n.string("Important")),
                    categoryToggle("summary", L10n.string("Neutral")),
                    categoryToggle("silence", L10n.string("Spam")),
                    .separator,
                    .header(L10n.string("Read state")),
                    readToggle(.unread, L10n.string("Unread")),
                    readToggle(.read, L10n.string("Read")),
                    .separator,
                    .item(L10n.string("Only what opens on this Mac"), isOn: inbox.showsOnlyOpenable) { inbox.showsOnlyOpenable.toggle() }
                ]
            }
            if inbox.selection.isEmpty {
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Select All"), symbol: "checklist") {
                    inbox.selection = Set(inbox.visibleItems.map(\.id))
                }
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Mark All Read"), symbol: "envelope.open") {
                    coordinator.markRead(Set(inbox.visibleItems.map(\.id)))
                }
                .disabled(!inbox.visibleItems.contains { $0.isUnread })
            } else {
                BarMenuButton(mode: inbox.barDisplayMode, label: L10n.string("Mark as"), symbol: "tag") {
                    var entries: [BarMenuEntry] = [
                        .item(L10n.string("Important"), isEnabled: !inbox.allHaveCategory("notifyNow", ids: inbox.selection)) { coordinator.setCategory("notifyNow", inbox.selection) },
                        .item(L10n.string("Neutral"), isEnabled: !inbox.allHaveCategory("summary", ids: inbox.selection)) { coordinator.setCategory("summary", inbox.selection) },
                        .item(L10n.string("Spam"), isEnabled: !inbox.allHaveCategory("silence", ids: inbox.selection)) { coordinator.setCategory("silence", inbox.selection) }
                    ]
                    // Read only when something selected is still unread.
                    if inbox.selectedItems.contains(where: \.isUnread) {
                        entries += [.separator, .item(L10n.string("Read")) { coordinator.markRead(inbox.selection) }]
                    }
                    return entries
                }
                BarButton(mode: inbox.barDisplayMode, label: L10n.string("Delete"), symbol: "trash", role: .destructive) {
                    coordinator.delete(inbox.selection)
                }
            }
        }
        .padding(.horizontal, 12)
        // A fixed height: the buttons change with the selection, and a menu's face
        // and a button's differ by a point or two, which would move the list.
        .frame(height: inbox.barDisplayMode == .iconAndText ? 52 : 40)
        .contentShape(Rectangle())
        .contextMenu { BarDisplayModePicker(inbox: inbox) }
    }

    /// The grouping on the View as button's face.
    private var groupingSymbol: String {
        switch coordinator.inbox.grouping {
        case .none: "list.bullet"
        case .apps: "square.grid.2x2"
        case .senders: "person.2"
        case .threads: "bubble.left.and.bubble.right"
        }
    }

    private var isFiltering: Bool {
        coordinator.inbox.shownCategories.count < Inbox.categories.count
            || coordinator.inbox.shownReadStates.count < Inbox.ReadState.allCases.count
            || coordinator.inbox.showsOnlyOpenable
    }

    private func categoryToggle(_ category: String, _ label: String) -> BarMenuEntry {
        let inbox = coordinator.inbox
        return .item(label, isOn: inbox.shownCategories.contains(category)) {
            if inbox.shownCategories.contains(category) { inbox.shownCategories.remove(category) } else { inbox.shownCategories.insert(category) }
        }
    }

    private func readToggle(_ state: Inbox.ReadState, _ label: String) -> BarMenuEntry {
        let inbox = coordinator.inbox
        return .item(label, isOn: inbox.shownReadStates.contains(state)) {
            if inbox.shownReadStates.contains(state) { inbox.shownReadStates.remove(state) } else { inbox.shownReadStates.insert(state) }
        }
    }
}

/// The bar over one notification in full: the way back and what can be done to
/// it. Its name is in the title bar. Escape goes back; Delete deletes it.
private struct DetailBar: View {
    let coordinator: AppCoordinator
    let item: Inbox.Item

    var body: some View {
        let inbox = coordinator.inbox
        HStack(spacing: 12) {
            BarButton(mode: inbox.barDisplayMode, label: L10n.string("Back"), symbol: "chevron.left") {
                inbox.openItemID = nil
            }
            Spacer()
            BarMenuButton(mode: inbox.barDisplayMode, label: L10n.string("Mark as"), symbol: "tag") {
                var entries: [BarMenuEntry] = [
                    .item(L10n.string("Important"), isEnabled: item.category != "notifyNow") { coordinator.setCategory("notifyNow", [item.id]) },
                    .item(L10n.string("Neutral"), isEnabled: item.category != "summary") { coordinator.setCategory("summary", [item.id]) },
                    .item(L10n.string("Spam"), isEnabled: item.category != "silence") { coordinator.setCategory("silence", [item.id]) }
                ]
                if item.isUnread {
                    entries += [.separator, .item(L10n.string("Read")) { coordinator.markRead([item.id]) }]
                }
                return entries
            }
            BarButton(mode: inbox.barDisplayMode, label: L10n.string("Delete"), symbol: "trash", role: .destructive) {
                delete()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: inbox.barDisplayMode == .iconAndText ? 52 : 40)
        .contentShape(Rectangle())
        .contextMenu { BarDisplayModePicker(inbox: inbox) }
    }

    private func delete() {
        coordinator.deleteOpenItem()
    }
}

/// What a bar menu holds: items with an optional check, headers, separators.
enum BarMenuEntry {
    case item(String, isOn: Bool? = nil, isEnabled: Bool = true, action: @MainActor () -> Void)
    case header(String)
    case separator
}

/// A bar button that drops an AppKit menu below itself. SwiftUI's Menu lays its
/// label out as a row, icon then text, whatever the label; a plain button keeps
/// the bar's face, and the menu is popped by hand.
private struct BarMenuButton: View {
    let mode: Inbox.BarDisplayMode
    let label: String
    let symbol: String
    let entries: @MainActor () -> [BarMenuEntry]
    @State private var anchor = AnchorView.Box()

    var body: some View {
        Button {
            show()
        } label: {
            BarLabel(mode: mode, label: label, symbol: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
        .background(AnchorView(box: anchor))
    }

    private func show() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            switch entry {
            case let .item(title, isOn, isEnabled, action):
                let item = ClosureMenuItem(title: title, action: action)
                if let isOn { item.state = isOn ? .on : .off }
                item.isEnabled = isEnabled
                menu.addItem(item)
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let closure: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        closure = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        closure()
    }
}

/// An empty view under a button, for the AppKit view to hang a menu from.
private struct AnchorView: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The display modes a toolbar would offer, for a bar's right-click menu.
private struct BarDisplayModePicker: View {
    let inbox: Inbox

    var body: some View {
        @Bindable var inbox = inbox
        Picker("", selection: $inbox.barDisplayMode) {
            Text(L10n.string("Icon and Text")).tag(Inbox.BarDisplayMode.iconAndText)
            Text(L10n.string("Icon Only")).tag(Inbox.BarDisplayMode.iconOnly)
            Text(L10n.string("Text Only")).tag(Inbox.BarDisplayMode.textOnly)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// A bar button's face in the chosen display mode.
private struct BarLabel: View {
    let mode: Inbox.BarDisplayMode
    let label: String
    let symbol: String

    var body: some View {
        Group {
            switch mode {
            case .iconAndText:
                VStack(spacing: 2) {
                    icon
                    Text(label).font(.caption2)
                }
            case .iconOnly:
                icon
            case .textOnly:
                Text(label)
            }
        }
        .frame(height: mode == .iconAndText ? 36 : 24)
    }

    /// Symbols differ in height; a fixed box keeps every label on one line.
    private var icon: some View {
        Image(systemName: symbol)
            .font(.body)
            .frame(width: 22, height: 20)
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
        // A new grouping starts at its own list, from the top.
        .onChange(of: inbox.grouping) { _, _ in inbox.openGroupID = nil; inbox.openItemID = nil }
        .id("\(inbox.grouping.rawValue)-\(inbox.openGroupID ?? "")")
    }
}

/// A notification in full, for one with nowhere else to open. It takes the
/// keyboard so Escape goes back and Delete deletes it.
private struct ItemDetail: View {
    let item: Inbox.Item
    let onBack: () -> Void
    let onDelete: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onExitCommand(perform: onBack)
            .onDeleteCommand(perform: onDelete)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(item.app).foregroundStyle(.secondary)
                    VerdictBadge(verdict: item.verdict, chosen: item.chosenCategory, isWaiting: item.isWaitingForVerdict)
                    Spacer()
                    Text(item.deliveredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                if let title = item.title, !title.isEmpty {
                    Text(title).font(.title3.weight(.semibold))
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.headline)
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                }
                if let reason = item.verdict?.reason, !reason.isEmpty {
                    Divider()
                    Text(reason).foregroundStyle(.secondary)
                }
                if item.readAt != nil {
                    Text(L10n.string("Read here; cleared on the iPhone")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
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

/// Apps, senders, or threads as a table: the name, the app, how many, how many
/// unread, and the newest's time. Columns sort and move like the notifications'.
/// A double-click opens the group.
private struct GroupsList: View {
    let inbox: Inbox
    @Binding var openGroupID: String?
    @State private var selection: Set<String> = []
    @AppStorage(DemoMode.isActive ? "inbox.groupColumns.demo" : "inbox.groupColumns") private var columns: TableColumnCustomization<Inbox.Group>

    var body: some View {
        @Bindable var inbox = inbox
        let groups = inbox.groups.sorted(using: inbox.groupSortOrder)
        Table(groups, selection: $selection, sortOrder: $inbox.groupSortOrder, columnCustomization: $columns) {
            TableColumn("") { group in
                Circle()
                    .fill(group.unreadCount > 0 ? Color.accentColor : Color.clear)
                    .frame(width: 8, height: 8)
            }
            .width(12)
            .customizationID("unread-dot")
            .disabledCustomizationBehavior(.resize)
            TableColumn(L10n.string("Name"), value: \.title) { group in
                Text(group.title).fontWeight(group.unreadCount > 0 ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 120, ideal: 240)
            .customizationID("name")
            TableColumn(L10n.string("App"), value: \.app) { group in
                Text(group.app).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 96, max: 140)
            .customizationID("app")
            TableColumn(L10n.string("Count"), value: \.count) { group in
                Text("\(group.count)").font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 80)
            .customizationID("count")
            TableColumn(L10n.string("Unread"), value: \.unreadCount) { group in
                Text(group.unreadCount > 0 ? "\(group.unreadCount)" : "").font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64, max: 80)
            .customizationID("unreadCount")
            TableColumn(L10n.string("Newest"), value: \.newestAt) { group in
                Text(group.newestAt, format: Calendar.current.isDateInToday(group.newestAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 76, max: 170)
            .customizationID("newest")
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
            if let id = ids.first { openGroupID = id }
        }
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first else { return .ignored }
            openGroupID = id
            return .handled
        }
    }
}

/// The notifications, sorted as the columns say. Compact: a table whose columns
/// resize and sort by their headers. Expanded: a list of fuller rows in the same
/// order.
private struct ItemsList: View {
    let coordinator: AppCoordinator
    let items: [Inbox.Item]
    /// The columns' widths and order, kept across launches.
    @AppStorage(DemoMode.isActive ? "inbox.columns.demo" : "inbox.columns") private var columns: TableColumnCustomization<Inbox.Item>

    var body: some View {
        @Bindable var inbox = coordinator.inbox
        let sorted = items.sorted(using: inbox.sortOrder)
        Group {
            if inbox.isCompact {
                Table(sorted, selection: $inbox.selection, sortOrder: $inbox.sortOrder, columnCustomization: $columns) {
                    TableColumn("") { item in
                        Circle()
                            .fill(item.isUnread ? Color.accentColor : Color.clear)
                            .frame(width: 8, height: 8)
                    }
                    .width(12)
                    // Movable like the others; its width stays fixed.
                    .customizationID("unread")
                    TableColumn(L10n.string("Category"), value: \.categoryRank) { item in
                        VerdictBadge(verdict: item.verdict, chosen: item.chosenCategory, isWaiting: item.isWaitingForVerdict)
                    }
                    .width(min: 76, ideal: 96, max: 104)
                    .customizationID("category")
                    TableColumn(L10n.string("App"), value: \.app) { item in
                        Text(item.app).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 96, max: 112)
                    .customizationID("app")
                    TableColumn(L10n.string("Sender"), value: \.sender) { item in
                        Text(item.sender).lineLimit(1).truncationMode(.tail)
                    }
                    .width(min: 90, ideal: 150, max: 170)
                    .customizationID("sender")
                    TableColumn(L10n.string("Notification"), value: \.compactLine) { item in
                        Text(item.compactLine).lineLimit(1).truncationMode(.tail)
                    }
                    .customizationID("notification")
                    TableColumn(L10n.string("Time"), value: \.deliveredAt) { item in
                        Text(item.deliveredAt, format: Calendar.current.isDateInToday(item.deliveredAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 56, ideal: 76, max: 170)
                    .customizationID("time")
                }
                .modifier(ItemActions(coordinator: coordinator))
            } else {
                List(sorted, selection: $inbox.selection) { item in
                    InboxRow(coordinator: coordinator, item: item)
                }
                .modifier(ItemActions(coordinator: coordinator))
            }
        }
    }
}

/// What a right-click, a double-click, Delete, and Escape do to the items.
private struct ItemActions: ViewModifier {
    let coordinator: AppCoordinator

    func body(content: Content) -> some View {
        let inbox = coordinator.inbox
        content
            .contextMenu(forSelectionType: String.self) { ids in
                let ids = ids.isEmpty ? inbox.selection : ids
                if inbox.items.contains(where: { ids.contains($0.id) && $0.isUnread }) {
                    Button(L10n.string("Mark as Read")) { coordinator.markRead(ids) }
                }
                Menu(L10n.string("Mark as")) {
                    Button(L10n.string("Important")) { coordinator.setCategory("notifyNow", ids) }
                        .disabled(inbox.allHaveCategory("notifyNow", ids: ids))
                    Button(L10n.string("Neutral")) { coordinator.setCategory("summary", ids) }
                        .disabled(inbox.allHaveCategory("summary", ids: ids))
                    Button(L10n.string("Spam")) { coordinator.setCategory("silence", ids) }
                        .disabled(inbox.allHaveCategory("silence", ids: ids))
                }
                Divider()
                Button(L10n.string("Delete"), role: .destructive) { coordinator.delete(ids) }
            } primaryAction: { ids in
                // A double-click opens the item where it has somewhere to open, shows it
                // in full here otherwise, and counts as reading it either way.
                let opened = inbox.items.filter { ids.contains($0.id) }
                if opened.count == 1, let item = opened.first {
                    coordinator.open(item)
                } else {
                    for item in opened where item.link != nil { coordinator.open(item) }
                }
                coordinator.markRead(ids)
            }
            .onDeleteCommand {
                coordinator.delete(inbox.selection)
            }
            .onExitCommand {
                inbox.selection = []
            }
            .onKeyPress(.return) {
                guard inbox.selection.count == 1 else { return .ignored }
                coordinator.openSelection()
                return .handled
            }
    }
}

/// An expanded row: the app and verdict, the text, the reason, and Open.
private struct InboxRow: View {
    let coordinator: AppCoordinator
    let item: Inbox.Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
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
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.deliveredAt, format: Calendar.current.isDateInToday(item.deliveredAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
                if item.link != nil || item.app == KnownApp.messages.rawValue {
                    Button(L10n.string("Open")) {
                        coordinator.open(item)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .tag(item.id)
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
