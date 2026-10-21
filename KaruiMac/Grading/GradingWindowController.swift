#if DEBUG
import AppKit
import SwiftUI

/// Developer builds: the grading window, opened from Help → Grade History….
@MainActor
final class GradingWindowController: NSObject, NSWindowDelegate {
    static let shared = GradingWindowController()

    private var window: NSWindow?
    private var session: GradingSession?

    func show(inbox: Inbox) {
        if window == nil {
            let session = GradingSession(macHistory: {
                inbox.items.compactMap(GradingSession.Item.init(inboxItem:))
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Grade History"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 520, height: 440)
            window.setFrameAutosaveName("KaruiGrading")
            window.delegate = self
            window.contentView = NSHostingView(rootView: GradingView(session: session))
            self.session = session
            self.window = window
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The inbox keeps taking the iPhone's verdicts; coming back picks up the new ones.
    func windowDidBecomeKey(_ notification: Notification) {
        session?.refreshMacHistory()
    }
}

extension GradingSession.Item {
    /// This Mac's copy of a History item, from the verdict the iPhone sent with
    /// History's own text and sort time. Nil for a notification the iPhone never sorted.
    init?(inboxItem: Inbox.Item) {
        guard let verdict = inboxItem.verdict else { return nil }
        // A category chosen here is the person's fix, until the iPhone's verdict
        // catches up and the Mac stops knowing it was one.
        let chosen = inboxItem.chosenCategory.flatMap { $0 == verdict.category ? nil : $0 }
        self.init(
            line: GradingSession.ExportLine(
                triagedAt: verdict.triagedAt,
                source: verdict.app,
                sender: verdict.sender ?? inboxItem.senderName,
                title: verdict.title ?? inboxItem.title ?? "",
                subtitle: verdict.subtitle ?? inboxItem.subtitle,
                body: verdict.body ?? inboxItem.body ?? "",
                recipients: verdict.recipients ?? inboxItem.recipients,
                category: chosen ?? verdict.category,
                reason: verdict.reason,
                originalCategory: chosen == nil ? nil : verdict.category,
                triggers: chosen == nil ? nil : ["correction"]
            ),
            origin: .mac,
            raw: nil
        )
    }
}
#endif
