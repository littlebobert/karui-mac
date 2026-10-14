import KaruiLinkKit
import SwiftUI

enum InboxWindow {
    static let id = "inbox"
}

struct InboxView: View {
    let coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !coordinator.fullDiskAccess.isGranted {
                FullDiskAccessCard(fullDiskAccess: coordinator.fullDiskAccess)
            }
            InboxList(inbox: coordinator.inbox)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 400)
        .onAppear { coordinator.inboxWindowAppeared() }
        .onDisappear { coordinator.inboxWindowClosed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.applicationDidBecomeActive()
        }
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

/// The day's notifications with Karui's verdict on each, newest first.
private struct InboxList: View {
    let inbox: Inbox

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Today"))
                .font(.headline)
            if inbox.items.isEmpty {
                Text(L10n.string("Nothing yet. Notifications from Messages, Spark, and Slack appear here as they arrive on this Mac, with what Karui on your iPhone decided about each."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(inbox.items) { item in
                    InboxRow(item: item)
                }
            }
        }
    }
}

private struct InboxRow: View {
    let item: Inbox.Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VerdictBadge(verdict: item.verdict, isWaiting: item.isWaitingForVerdict)
                }
                if let title = item.title, !title.isEmpty {
                    Text(title).fontWeight(.semibold)
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let reason = item.verdict?.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if item.readAt != nil {
                    Text(L10n.string("Read here; cleared on the iPhone"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.deliveredAt, style: .time)
                    .foregroundStyle(.secondary)
                if let link = item.link {
                    HStack {
                        Button(L10n.string("Open")) {
                            NSWorkspace.shared.open(link.url)
                        }
                        Button(L10n.string("Copy Link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Karui's category, in its colors; "Sorting…" until the iPhone's verdict arrives.
private struct VerdictBadge: View {
    let verdict: VerdictRecord?
    let isWaiting: Bool

    var body: some View {
        let (label, color): (String, Color) = switch verdict?.category {
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
