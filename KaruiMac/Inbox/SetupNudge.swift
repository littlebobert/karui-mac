import Foundation
import KaruiSorting
import Observation
import SwiftUI

/// One step toward sorting on this Mac, offered at the top of the inbox: only the
/// next one that's missing, gone by itself once done, and gone for good after Not
/// Now. Sorting here is on by default; what keeps it from working is the iPhone's
/// settings not having arrived, or the Shortcut Second Opinion needs.
@MainActor
@Observable
final class SetupNudge {
    enum Step: String, CaseIterable {
        /// The iPhone hasn't sent its settings: Show History on your Mac is off there.
        case iPhoneSettings
        /// Second Opinion is on in Karui on the iPhone, and the Shortcut is missing here.
        case secondOpinionShortcut
        /// Sorting works; notifications only this Mac received could reach the iPhone too.
        case sendToIPhone
    }

    private static let dismissedKey = "setupNudge.dismissed"
    private(set) var isShortcutInstalled: Bool?
    private var dismissed: Set<String>
    /// Developer builds: a step shown whatever the state, from the Help menu.
    var forcedStep: Step?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    func step(settings: AppSettings, sorting: SortingSettingsStore, canSort: Bool) -> Step? {
        if let forcedStep { return forcedStep }
        guard #available(macOS 26.0, *), settings.sortsOnThisMac, sorting.hasChecked else { return nil }
        let next: Step? = if sorting.policy == nil {
            .iPhoneSettings
        } else if sorting.policy?.secondOpinionEnabled == true, isShortcutInstalled == false {
            .secondOpinionShortcut
        } else if canSort, !settings.asksIPhoneToSort {
            .sendToIPhone
        } else {
            nil
        }
        return next.flatMap { dismissed.contains($0.rawValue) ? nil : $0 }
    }

    func dismiss(_ step: Step) {
        if forcedStep == step { forcedStep = nil }
        dismissed.insert(step.rawValue)
        defaults.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    /// Developer builds: every step can show again.
    func resetDismissed() {
        dismissed = []
        defaults.removeObject(forKey: Self.dismissedKey)
    }

    func refreshShortcut(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isShortcutInstalled = name.isEmpty ? false : await MacSecondOpinion.isInstalled(name: name)
    }
}

struct SetupNudgeCard: View {
    let step: SetupNudge.Step
    let onTurnOnSending: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        switch step {
                        case .iPhoneSettings:
                            EmptyView()
                        case .secondOpinionShortcut:
                            Button(L10n.string("Get the Shortcut")) {
                                NSWorkspace.shared.open(MacSecondOpinion.shortcutURL)
                            }
                        case .sendToIPhone:
                            Button(L10n.string("Turn On"), action: onTurnOnSending)
                        }
                        Button(L10n.string("Not Now"), action: onDismiss)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var icon: String {
        switch step {
        case .iPhoneSettings: "iphone"
        case .secondOpinionShortcut: "cloud"
        case .sendToIPhone: "arrow.up.forward.app"
        }
    }

    private var title: String {
        switch step {
        case .iPhoneSettings: L10n.string("Sort notifications the moment they arrive")
        case .secondOpinionShortcut: L10n.string("Add the Second Opinion Shortcut")
        case .sendToIPhone: L10n.string("Get notifications only this Mac received on your iPhone")
        }
    }

    private var message: String {
        switch step {
        case .iPhoneSettings:
            L10n.string("This Mac can sort each notification with your iPhone’s settings as soon as it arrives. In Karui on your iPhone, open Settings → Karui for Mac and turn on Show History on your Mac.")
        case .secondOpinionShortcut:
            L10n.string("Second Opinion is on in Karui on your iPhone. This Mac asks Apple’s Private Cloud Compute through a Shortcut of your own, with the same prompt your iPhone sends.")
        case .sendToIPhone:
            L10n.string("When your iPhone never got a notification, this Mac can send it there, already sorted and end-to-end encrypted, so it shows in History and alerts you if it’s Important.")
        }
    }
}
