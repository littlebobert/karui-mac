import AppIntents
import Foundation

/// Lets Karui for Mac know a Focus is on, as Karui Filtering does on the iPhone. The
/// Focus keeps this Mac's apps quiet; while it's on, their Important notifications
/// come again as Karui's own (`MacRepost`). The filter is the switch: added to a
/// Focus on this Mac, with nothing to turn on in Karui.
struct MacFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Karui Filtering"
    static let description = IntentDescription("Lets Karui know this Focus is on, so it shows Important notifications from your Mac’s apps while they’re silenced.")

    @Parameter(title: "Show Important notifications with Karui", default: false)
    var showsImportant: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Karui Filtering",
            subtitle: showsImportant ? "On" : "Off"
        )
    }

    /// Offered in the Focus's filter list with the switch already on, so adding it
    /// there needs no second step.
    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [MacFocusFilter] {
        var filter = MacFocusFilter()
        filter.showsImportant = true
        return [filter]
    }

    func perform() async throws -> some IntentResult {
        MacFocusState.note(isFiltering: showsImportant)
        SafeDiagnosticLog.shared.record(showsImportant ? "focus: on" : "focus: off")
        return .result()
    }
}

/// Whether a Focus with Karui's filter is on, here.
enum MacFocusState {
    private static let isFilteringKey = "focus.isFiltering"
    private static let hasRunKey = "focus.hasRun"

    static func note(isFiltering: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isFiltering, forKey: isFilteringKey)
        defaults.set(true, forKey: hasRunKey)
    }

    /// Whether macOS has ever run the filter here: once it has, it's on a Focus.
    static func hasRun(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hasRunKey)
    }

    /// The filter as it is now, which macOS answers with the default, off, when no
    /// Focus with it is on; the last one macOS ran when asking fails.
    static func isFiltering(defaults: UserDefaults = .standard) async -> Bool {
        do {
            return try await MacFocusFilter.current.showsImportant
        } catch {
            SafeDiagnosticLog.shared.record("focus: asking for the filter failed: \(error.localizedDescription)")
            return defaults.bool(forKey: isFilteringKey)
        }
    }
}
