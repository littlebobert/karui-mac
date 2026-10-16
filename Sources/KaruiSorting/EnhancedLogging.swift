import Foundation

/// How errors appear in Karui's log. An error's message can quote the notification
/// (a decoding failure, for example, carries the text the model wrote about it), so
/// by default only where the error comes from is logged publicly: its type, its
/// case, and its domain and code, which never hold notification text. Enhanced
/// Logging, a developer setting, adds the full message, also publicly.
public enum EnhancedLogging {
    public static let key = "karui.developer.enhancedLogging"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// For logging publicly: the error's kind, then its message with Enhanced Logging on.
    public static func describe(_ error: any Error, defaults: UserDefaults = .standard) -> String {
        let kind = kind(of: error)
        guard isEnabled(defaults: defaults) else { return kind }
        return "\(kind): \(String(describing: error))"
    }

    /// Like `describe`, for a message Karui already wrote from an error.
    public static func describe(detail: String, defaults: UserDefaults = .standard) -> String {
        isEnabled(defaults: defaults) ? detail : "details hidden; turn on Enhanced Logging to see them"
    }

    /// For example "FoundationModels.LanguageModelSession.GenerationError.rateLimited
    /// (code 5)": the case's name without the values it carries.
    public static func kind(of error: any Error) -> String {
        let nsError = error as NSError
        let mirror = Mirror(reflecting: error)
        var name = String(reflecting: type(of: error))
        if mirror.displayStyle == .enum {
            // A case with values shows as its label; one without shows as itself.
            name += "." + (mirror.children.first?.label ?? String(describing: error))
        }
        return "\(name) (\(nsError.domain) code \(nsError.code))"
    }
}
