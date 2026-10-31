import KaruiSorting
import SwiftUI

/// The iPhone's sorting settings as this Mac has them (`SortingSettingsStore`), to
/// see what the Mac sorts with. Read only: Karui on the iPhone is where they change,
/// and a change reaches the Mac within minutes.
struct IPhoneSortingSettingsSection: View {
    let policy: TriagePolicy
    let updatedAt: Date?

    var body: some View {
        Section {
            Group {
                row("VIPs", list(policy.vipIdentities.map(\.displayName)))
                row("Your names", terms(policy.userNames))
                row("Important apps", list(policy.importantApps.filter { app in !policy.workApps.contains(app) }))
                if !policy.workApps.isEmpty {
                    row("Work apps", list(policy.workApps))
                    row("Work hours", workHours)
                }
                row("Quiet apps", list(policy.quietApps))
                row("Important terms", terms(policy.urgentKeywords))
                row("Neutral terms", terms(policy.summaryKeywords))
                row("Spam terms", terms(policy.silenceKeywords))
                row("Promotions", L10n.string(policy.silencePromotions ? "Spam" : "Neutral"))
                row("Prioritize calendar and travel", onOff(policy.prioritizeCalendarAndTravel))
                row("Always alert for saved contacts", onOff(policy.alertSavedContacts))
                row("Alert for senders you’ve written to", onOff(policy.alertKnownCorrespondents))
                row("Always alert for one-time codes", onOff(policy.alertOneTimeCodes))
                row("Important Conversations", list(policy.importantConversations.map(\.name)))
                row("Learned", L10n.format("%lld fixes", Int64(learnedCount)))
                row("Private Cloud Sorting", secondOpinion)
            }
        } header: {
            Text(L10n.string("Your iPhone’s sorting settings"))
        } footer: {
            Text(updatedAt.map {
                L10n.format("Change these in Karui on your iPhone. These are from %@.", $0.formatted(date: .abbreviated, time: .shortened))
            } ?? L10n.string("Change these in Karui on your iPhone."))
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(L10n.string(title)) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func list(_ items: [String]) -> String {
        items.isEmpty ? L10n.string("None") : ListFormatter.localizedString(byJoining: items)
    }

    private func terms(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("None") : trimmed
    }

    private func onOff(_ isOn: Bool) -> String {
        L10n.string(isOn ? "On" : "Off")
    }

    private var workHours: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = policy.workDays.sorted().compactMap { $0 >= 1 && $0 <= 7 ? symbols[$0 - 1] : nil }
        return "\(ListFormatter.localizedString(byJoining: days)), \(time(policy.workStartMinuteOfDay))–\(time(policy.workEndMinuteOfDay))"
    }

    private func time(_ minuteOfDay: Int) -> String {
        String(format: "%d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    private var secondOpinion: String {
        guard policy.secondOpinionEnabled else { return L10n.string("Off") }
        return L10n.string(policy.secondOpinionMode.asksAboutEveryModelAnswer ? "Before Alerting" : "Only When Needed")
    }

    private var learnedCount: Int {
        CorrectionMemory.examples(fileURL: MacSortingFiles.corrections).count
    }
}
