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
            HarvestedLinksView(log: coordinator.harvestLog)
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

private struct HarvestedLinksView: View {
    let log: HarvestLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Links found"))
                .font(.headline)
            if log.entries.isEmpty {
                Text(L10n.string("Nothing yet. Links appear here as notifications from Messages, Spark, and Slack arrive on this Mac."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(log.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.link.app)
                            Text(entry.link.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(L10n.string(entry.link.opensExactContent ? "Opens the exact item" : "Opens the conversation"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.link.deliveredAt, style: .time)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("Open")) {
                            NSWorkspace.shared.open(entry.link.url)
                        }
                        Button(L10n.string("Copy Link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.link.url.absoluteString, forType: .string)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
