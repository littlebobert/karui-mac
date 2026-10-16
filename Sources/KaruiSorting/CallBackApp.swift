import Foundation

/// Which system calling app a missed-call notification came from.
public enum CallBackApp: Equatable, Sendable {
    case faceTime
    case phone

    /// The calling app a missed-call notification came from, by the app's name.
    public init?(source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "電話" || trimmed == "전화" {
            self = .phone
            return
        }
        let normalized = SourceAppRouter.normalize(trimmed)
        if normalized == "facetime" || normalized == "face time"
            || normalized.hasPrefix("facetime ") || normalized.hasPrefix("face time ") {
            self = .faceTime
        } else if normalized == "phone" || normalized == "phone app" {
            self = .phone
        } else {
            return nil
        }
    }

    public func displayName(locale: Locale = .current) -> String {
        switch self {
        case .faceTime: "FaceTime"
        case .phone: KaruiLocalization.string("Phone", locale: locale)
        }
    }
}
