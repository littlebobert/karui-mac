import AppKit
import SwiftUI

/// About Karui: the icon, the version, the line, a link home, Report a Bug, and
/// the acknowledgements, in a small fixed window.
@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var acknowledgementsWindow: NSWindow?

    func show() {
        if window == nil {
            window = makeWindow()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("About Karui")
        Self.centerTitle(of: window)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AboutView(showAcknowledgements: { [weak self] in
            self?.showAcknowledgements()
        }))
        return window
    }

    /// The licenses of what the app ships with, from the bundled text.
    private func showAcknowledgements() {
        if acknowledgementsWindow == nil {
            let text = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.string("Acknowledgements")
            Self.centerTitle(of: window)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            })
            acknowledgementsWindow = window
        }
        acknowledgementsWindow?.center()
        acknowledgementsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AboutWindowController {
    /// Linked against the macOS 26 SDK and later, a window's title sits at the
    /// left. As Kehai does: the system title is hidden and a label is put in the
    /// title bar, centered on the close button's row.
    static func centerTitle(of window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarView = closeButton.superview else { return }
        let label = NSTextField(labelWithString: window.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        titlebarView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])
    }
}

private struct AboutView: View {
    let showAcknowledgements: () -> Void
    @State private var reportError: String?

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 60, height: 60)

            VStack(spacing: 4) {
                Text(L10n.string("Karui for Mac"))
                    .font(.title2.bold())
                Text(L10n.format("Version %@", version))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.string("Makes Karui for iPhone even smarter"))
                .multilineTextAlignment(.center)

            Link(L10n.string("Made in Japan"), destination: URL(string: "https://karui.jp/mac")!)
                .font(.callout)

            HStack(spacing: 8) {
                Button(L10n.string("Report a Bug")) {
                    reportBug()
                }
                Button(L10n.string("Acknowledgements")) {
                    showAcknowledgements()
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, 5)

            if let reportError {
                Text(reportError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(width: 300, height: 250)
    }

    private func reportBug() {
        reportError = BugReport.compose()
    }
}

enum BugReport {
    /// An email with the diagnostics: app names, counts, and failures, never
    /// notification text. Returns what went wrong when Mail can't be opened; the
    /// report is on the pasteboard then.
    @MainActor
    static func compose() -> String? {
        guard let service = NSSharingService(named: .composeEmail) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DiagnosticReport.text(), forType: .string)
            return L10n.string("Could not open Mail. The report was copied instead.")
        }
        service.recipients = ["justin.garcia@gmail.com"]
        service.subject = "Karui for Mac Bug Report"
        service.perform(withItems: [
            L10n.string("Please describe what happened and what you expected.") + "\n\n" + DiagnosticReport.text()
        ])
        return nil
    }
}

enum DiagnosticReport {
    static func text() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let events = SafeDiagnosticLog.shared.recentText()
        return """
        Karui for Mac Diagnostics
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        Recent events
        \(events.isEmpty ? "No events recorded." : events)
        """
    }
}
