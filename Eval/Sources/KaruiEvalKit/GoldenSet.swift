import Foundation
import KaruiSorting

/// One line of a golden set from Grade History's Export Golden Set: the notification
/// as History has it, and the person's grade.
public struct GoldenItem: Codable, Equatable, Sendable {
    public var triagedAt: Date
    public var source: String
    public var sender: String?
    public var title: String
    public var subtitle: String?
    public var body: String
    public var recipients: String?
    public var isTimeSensitive: Bool?
    /// Karui's category in History when it was graded, fixes included.
    public var category: String
    /// The grade: a `TriageCategory` raw value, or `ambiguous`.
    public var label: String
    /// What decided the category as it stands, as `ClassificationEngine` names it.
    public var engine: String?
    /// What made the first sort, and whether that was the rules only because the
    /// on-device model couldn't answer. From Karui 0.2.3's export; older exports have
    /// only `engine`.
    public var firstEngine: String?
    public var firstWasModelFallback: Bool?

    public init(
        triagedAt: Date, source: String, sender: String? = nil, title: String, subtitle: String? = nil,
        body: String, recipients: String? = nil, isTimeSensitive: Bool? = nil, category: String, label: String,
        engine: String? = nil, firstEngine: String? = nil, firstWasModelFallback: Bool? = nil
    ) {
        self.triagedAt = triagedAt
        self.source = source
        self.sender = sender
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.recipients = recipients
        self.isTimeSensitive = isTimeSensitive
        self.category = category
        self.label = label
        self.engine = engine
        self.firstEngine = firstEngine
        self.firstWasModelFallback = firstWasModelFallback
    }

    /// Decided by the rules alone (VIPs, @mentions, codes, urgent terms), which no
    /// prompt changes, so it isn't scored: by the first sort, as Grade History's
    /// Golden Set queue judges it, so a fallback the model should have given still counts.
    public var isDecidedByRules: Bool {
        guard firstWasModelFallback != true else { return false }
        return (firstEngine ?? engine) == ClassificationEngine.deterministicRules.rawValue
    }

    /// The grade as a category; nil when it was graded Unclear.
    public var labelCategory: TriageCategory? { TriageCategory(rawValue: label) }

    /// The notification as the Shortcut's input had it. History doesn't keep whether
    /// it was a direct message, so the prompt makes its usual guess; it doesn't keep
    /// the translation either.
    public var notification: NotificationInput {
        NotificationInput(
            source: source, title: title, body: body, sender: sender, isTimeSensitive: isTimeSensitive,
            subtitle: subtitle, receivedAt: triagedAt, recipients: recipients
        )
    }

    /// A line to tell items apart in a report.
    public var summary: String {
        let text = [title, body.replacingOccurrences(of: "\n", with: " ")]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return "\(source): " + (text.count > 90 ? text.prefix(89) + "…" : text)
    }

    public static func load(from url: URL) throws -> [GoldenItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: url).split(separator: 0x0A).filter { !$0.isEmpty }.enumerated().map { index, line in
            do {
                return try decoder.decode(GoldenItem.self, from: Data(line))
            } catch {
                throw EvalError("Line \(index + 1) of \(url.lastPathComponent) isn't a golden-set line: \(error)")
            }
        }
    }
}

public struct EvalError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
