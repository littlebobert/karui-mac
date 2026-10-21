#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Developer builds: the grading window's content; `GradingWindowController` opens it.
struct GradingView: View {
    @Bindable var session: GradingSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    private var header: some View {
        HStack {
            Picker(selection: $session.queue) {
                ForEach(GradingSession.Queue.allCases, id: \.self) { queue in
                    Text(verbatim: queue.title).tag(queue)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(verbatim: "\(session.remaining) to grade")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("\(session.macItems.count) from this Mac’s History, \(session.exportedItems.count) from iPhone exports"
                    + (session.queue == .golden && session.ruleDecidedCount > 0 ? "; \(session.ruleDecidedCount) the rules decided are left out" : ""))
            Spacer()
            Button { importHistory() } label: { Text(verbatim: "Import…") }
            Button { exportGoldenSet() } label: { Text(verbatim: "Export Golden Set…") }
                .disabled(session.grades.isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if session.items.isEmpty {
            ContentUnavailableView {
                Text(verbatim: "No History")
            } description: {
                Text(verbatim: "Turn on Show History on your Mac in Karui on the iPhone, or import an export: in an Xcode or TestFlight build, Help & Troubleshooting → Export History (JSON Lines), then AirDrop the file here.")
            }
            .frame(maxHeight: .infinity)
        } else if let item = session.current {
            VStack(spacing: 0) {
                ScrollView {
                    NotificationCard(line: item.line)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                gradeButtons
            }
            .id(item.id)
        } else {
            ContentUnavailableView {
                Text(verbatim: "Nothing Left to Grade")
            } description: {
                Text(verbatim: session.queue == .spotCheck
                    ? "Every Neutral and Spam from the past week is graded. Import a newer export for more."
                    : "Every imported item is graded. Import a newer export for more.")
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var gradeButtons: some View {
        HStack {
            ForEach(Array(GradingSession.Label.allCases.enumerated()), id: \.element) { index, label in
                Button { session.grade(label) } label: {
                    Text(verbatim: "\(label.title)  \(index + 1)").frame(minWidth: 84)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
            }
            Spacer()
            Button { session.skip() } label: { Text(verbatim: "Skip  ␣") }
                .keyboardShortcut(.space, modifiers: [])
            Button { session.undo() } label: { Text(verbatim: "Undo  ⌫") }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(session.grades.isEmpty)
        }
        .controlSize(.large)
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let grade = session.lastGrade, let item = session.items[grade.id] {
                // Revealed only once graded, so it can't anchor the grade.
                let agreed = item.line.category == grade.label.rawValue
                Text(verbatim: "Last: you said \(grade.label.title), Karui said \(GradingSession.Label.title(forCategory: item.line.category))"
                    + (item.line.decidedBy.map { " (\($0))" } ?? (item.origin == .mac ? " (from this Mac’s History)" : "")))
                    .foregroundStyle(grade.label == .unclear || agreed ? Color.secondary : Color.orange)
            }
            Text(verbatim: summary)
                .foregroundStyle(.secondary)
            if let message = session.message {
                Text(verbatim: message).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var summary: String {
        let all = session.tally()
        let graded = all.counts.values.reduce(0, +)
        let counts = GradingSession.Label.allCases.map { "\(all.counts[$0] ?? 0) \($0.title)" }.joined(separator: " · ")
        var text = "\(graded) graded: \(counts)"
        if all.compared > 0 {
            text += "\nKarui’s category matched yours on \(all.agreed) of \(all.compared) (\(percent(all.agreed, all.compared)))"
        }
        let week = session.spotCheckThisWeek
        let checked = week.counts.values.reduce(0, +)
        text += "\nSpot checks this week: \(checked) of \(GradingSession.spotCheckGoal)"
        if week.compared > 0 {
            text += ", \(week.compared - week.agreed) wrong"
        }
        return text
    }

    private func percent(_ part: Int, _ whole: Int) -> String {
        (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText, .json, .plainText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return }
        session.importHistory(from: panel.urls)
    }

    private func exportGoldenSet() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = GradingSession.goldenSetFileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.goldenSet().write(to: url, options: .atomic)
            session.message = "Exported \(session.latestGrades.count) graded items to \(url.lastPathComponent)."
        } catch {
            session.message = "Couldn’t export: \(error.localizedDescription)"
        }
    }
}

/// The notification as the classifier saw it, and nothing Karui decided.
private struct NotificationCard: View {
    let line: GradingSession.ExportLine

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Received", line.triagedAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
            row("App", line.source)
            row("Sender", line.sender)
            row("Recipients", line.recipients)
            if line.isTimeSensitive == true {
                row("", "Marked time sensitive")
            }
            row("Title", line.title)
            row("Subtitle", line.subtitle)
            row("Body", line.body)
            row("Language", line.detectedLanguage)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(verbatim: name)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(verbatim: value)
                    .font(name == "Body" || name == "Title" ? .body : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
