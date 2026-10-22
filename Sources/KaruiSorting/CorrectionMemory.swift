import CryptoKit
import Foundation
import OSLog

/// What Karui learned from History fixes: a notification someone downgraded from
/// Important teaches Karui to lower close matches from the same app; an upgrade to
/// Important teaches it not to. Matching compares character trigrams, which works in
/// every language and suits notifications, since apps send near-identical templates.
///
/// Examples keep the text's trigram hashes, not the text, and point at their History
/// item, so deleting the item forgets the example. The iPhone learns them; with Show
/// History on your Mac on, they go to Karui for Mac, encrypted, so it sorts the same way.
public struct CorrectionExample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The History item it came from, for its preview and so deleting it forgets this.
    public let recordID: UUID
    public let appKey: String
    public let appName: String
    /// A hash of the sender, so a person's message only matches that person's.
    public let senderKey: String?
    public let trigrams: [UInt32]
    /// What the person chose.
    public let category: TriageCategory
    /// What Karui had said.
    public let previousCategory: TriageCategory
    public let createdAt: Date
    /// The body alone, without the title. Apps like LinkedIn put a person's name in
    /// the title of a templated notification, which would make each one look new.
    /// Nil for examples learned before this was kept.
    public var bodyTrigrams: [UInt32]? = nil

    public init(
        id: UUID,
        recordID: UUID,
        appKey: String,
        appName: String,
        senderKey: String? = nil,
        trigrams: [UInt32],
        category: TriageCategory,
        previousCategory: TriageCategory,
        createdAt: Date,
        bodyTrigrams: [UInt32]? = nil
    ) {
        self.id = id
        self.recordID = recordID
        self.appKey = appKey
        self.appName = appName
        self.senderKey = senderKey
        self.trigrams = trigrams
        self.category = category
        self.previousCategory = previousCategory
        self.createdAt = createdAt
        self.bodyTrigrams = bodyTrigrams
    }

    /// An upgrade to Important, kept so close matches aren't lowered.
    public var isUpgrade: Bool { category == .notifyNow }
}

/// One example close enough to change a notification.
public struct CorrectionMatch: Equatable, Sendable {
    public let example: CorrectionExample
    public let similarity: Double
    /// Above zero when the sender was the reason, not the text: how many of their
    /// notifications were downgraded in a row.
    public var senderDowngrades = 0

    public init(
        example: CorrectionExample,
        similarity: Double,
        senderDowngrades: Int = 0
    ) {
        self.example = example
        self.similarity = similarity
        self.senderDowngrades = senderDowngrades
    }
}

public enum CorrectionMemory {
    public static let logger = Logger(subsystem: "com.justin.henry.karui", category: "CorrectionMemory")

    /// Similarity, from 0 to 1, a downgrade must reach to lower a notification.
    public static let defaultThreshold = 0.8
    /// How much closer the nearest downgrade must be than the nearest upgrade; when two
    /// corrections disagree, Karui leaves the notification alone.
    public static let disagreementMargin = 0.05
    /// Shorter texts share trigrams too easily to match on.
    public static let minimumTrigrams = 8
    public static let maximumExamples = 300

    public static let enabledKey = "karui.correctionMemory.enabled"
    /// Developer builds: overrides `defaultThreshold`, to tune it with Correction Replay.
    public static let thresholdKey = "karui.correctionMemory.threshold"

    public static var defaultFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("CorrectionMemory.json")
    }

    private static let lock = NSLock()

    /// Posted after what Karui learned is saved, so screens showing it can refresh.
    /// History's own change notice comes before the correction is learned.
    public static let didChange = Notification.Name("karui.correctionMemoryDidChange")

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    public static func threshold(defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: thresholdKey) as? Double ?? defaultThreshold
    }

    // MARK: Storing

    public static func examples(fileURL: URL = defaultFileURL) -> [CorrectionExample] {
        lock.lock()
        defer { lock.unlock() }
        return load(fileURL)
    }

    public static func forget(ids: Set<UUID>, fileURL: URL = defaultFileURL) {
        update(fileURL) { $0.removeAll { ids.contains($0.id) } }
    }

    /// History items were deleted: what was learned from them goes too.
    public static func forget(recordIDs: Set<UUID>, fileURL: URL = defaultFileURL) {
        update(fileURL) { $0.removeAll { recordIDs.contains($0.recordID) } }
    }

    public static func forgetAll(fileURL: URL = defaultFileURL) {
        update(fileURL) { $0.removeAll() }
    }

    // MARK: Matching

    /// The downgrade that would lower this notification, if one is close enough and no
    /// upgrade disagrees. `excluding` leaves out examples from one History item, so
    /// Correction Replay doesn't match a notification against its own fix.
    public static func match(
        title: String,
        body: String,
        source: String,
        sender: String?,
        in examples: [CorrectionExample],
        threshold: Double,
        excluding recordID: UUID? = nil,
        includingSenderRule: Bool = false
    ) -> CorrectionMatch? {
        let appKey = ImportantAppMatcher.canonicalKey(source)
        let isPersonalApp = isPersonalApp(appKey)
        let sender = senderKey(sender)
        // Off for real notifications: Correction Replay previews it. Two downgrades of
        // a colleague's messages needn't mean everything from them matters less.
        let senderMatch = includingSenderRule && isPersonalApp
            ? senderMatch(appKey: appKey, sender: sender, in: examples, excluding: recordID)
            : nil
        let target = Set(trigrams(of: text(title: title, body: body)))
        guard target.count >= minimumTrigrams else { return senderMatch }
        let targetBody = Set(trigrams(of: body))
        var bestDowngrade: CorrectionMatch?
        var bestUpgrade = 0.0
        for example in examples where example.appKey == appKey && example.recordID != recordID {
            if isPersonalApp, let exampleSender = example.senderKey, let sender, exampleSender != sender { continue }
            let similarity = similarity(of: target, body: targetBody, to: example, isPersonalApp: isPersonalApp)
            if example.isUpgrade {
                bestUpgrade = max(bestUpgrade, similarity)
            } else if similarity > (bestDowngrade?.similarity ?? 0) {
                bestDowngrade = CorrectionMatch(example: example, similarity: similarity)
            }
        }
        guard let bestDowngrade, bestDowngrade.similarity >= threshold,
              bestDowngrade.similarity > bestUpgrade + disagreementMargin else { return senderMatch }
        return bestDowngrade
    }

    /// Downgrades in a row from one sender before their later notifications are lowered.
    public static let senderDowngradeThreshold = 2

    /// In chat and mail apps, who it's from can say more than the text: someone whose
    /// notifications were downgraded twice running, with no upgrade since, would have
    /// their later ones lowered to what the latest was marked. A preview for now.
    public static func senderMatch(
        appKey: String,
        sender: String?,
        in examples: [CorrectionExample],
        excluding recordID: UUID? = nil
    ) -> CorrectionMatch? {
        guard let sender else { return nil }
        let theirs = examples
            .filter { $0.appKey == appKey && $0.senderKey == sender && $0.recordID != recordID }
            .sorted { $0.createdAt > $1.createdAt }
        let running = theirs.prefix { !$0.isUpgrade }
        guard running.count >= senderDowngradeThreshold, let latest = running.first else { return nil }
        return CorrectionMatch(example: latest, similarity: 1, senderDowngrades: running.count)
    }

    /// Lowers an Important result that closely matches a downgrade, as Quiet Apps does,
    /// and never for what Quiet Apps exempts: VIPs, codes, urgent terms, @mentions.
    public static func applying(
        to result: TriageResult,
        for notification: NotificationInput,
        policy: TriagePolicy,
        locale: Locale = .current,
        defaults: UserDefaults = .standard,
        fileURL: URL = defaultFileURL
    ) -> TriageResult {
        guard result.category == .notifyNow, isEnabled(defaults: defaults),
              !QuietApps.isExempt(result, notification: notification, policy: policy),
              let match = match(
                title: notification.title, body: notification.body, source: notification.source,
                sender: notification.sender, in: examples(fileURL: fileURL), threshold: threshold(defaults: defaults)
              ) else {
            return result
        }
        logger.notice("Lowered by a learned correction, similarity \(match.similarity, privacy: .public)")
        var lowered = TriageResult(
            category: match.example.category,
            confidence: result.confidence,
            reason: match.senderDowngrades > 0
                ? senderReason(for: match, sender: notification.sender ?? match.example.appName, locale: locale)
                : reason(for: match.example, locale: locale),
            engine: result.engine,
            engineDetail: result.engineDetail,
            resolvedVIPIdentityID: result.resolvedVIPIdentityID,
            resolvedVIPDisplayName: result.resolvedVIPDisplayName,
            interest: result.interest
        )
        lowered.isModelFallback = result.isModelFallback
        lowered.rateLimitResetDate = result.rateLimitResetDate
        lowered.tags = result.tags
        lowered.modelDuration = result.modelDuration
        return lowered
    }

    public static func reason(for example: CorrectionExample, locale: Locale = .current) -> String {
        KaruiLocalization.formatted(
            "Similar to a notification from %1$@ you marked %2$@ on %3$@.",
            example.appName,
            example.category.title(locale: locale),
            example.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)),
            locale: locale
        )
    }

    public static func senderReason(for match: CorrectionMatch, sender: String, locale: Locale = .current) -> String {
        KaruiLocalization.formatted(
            "You marked the last %1$lld notifications from %2$@ as less important.",
            Int64(match.senderDowngrades),
            sender,
            locale: locale
        )
    }

    /// Chat and mail apps, where a message is from a person: there, a correction only
    /// teaches about that person. Elsewhere the "sender" is whoever a templated
    /// notification names, like the person behind a LinkedIn invite, and the template
    /// is what was corrected.
    public static func isPersonalApp(_ appKey: String) -> Bool {
        personalApps.contains(appKey)
    }

    /// Where a message is from a person, that person is what mattered.
    public static let personalApps: Set<String> = [
        "messages", "imessage", "line", "whatsapp", "kakaotalk", "telegram", "messenger",
        "signal", "wechat", "viber", "mail", "gmail", "outlook", "spark"
    ].reduce(into: []) { $0.insert(ImportantAppMatcher.canonicalKey($1)) }

    /// How alike a notification and an example are, from 0 to 1. Outside chat and mail
    /// apps, the bodies alone also count, so a different name in the title doesn't
    /// hide the same template.
    public static func similarity(
        of text: Set<UInt32>,
        body: Set<UInt32>,
        to example: CorrectionExample,
        isPersonalApp: Bool
    ) -> Double {
        let whole = jaccard(text, Set(example.trigrams))
        guard !isPersonalApp, let exampleBody = example.bodyTrigrams,
              exampleBody.count >= minimumTrigrams, body.count >= minimumTrigrams else { return whole }
        return max(whole, jaccard(body, Set(exampleBody)))
    }

    // MARK: Text

    public static func text(title: String, body: String) -> String {
        "\(title) \(body)"
    }

    /// Lowercased, digits made alike so "40% off" matches "60% off", and runs of
    /// space collapsed, then hashed three characters at a time.
    public static func trigrams(of text: String) -> [UInt32] {
        var normalized = ""
        var lastWasSpace = true
        for character in text.lowercased() {
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace { normalized.append(" ") }
                lastWasSpace = true
            } else {
                normalized.append(character.isNumber ? "0" : character)
                lastWasSpace = false
            }
        }
        let characters = Array(normalized.trimmingCharacters(in: .whitespaces))
        guard characters.count >= 3 else { return [] }
        var hashes = Set<UInt32>()
        for index in 0...(characters.count - 3) {
            hashes.insert(fnv1a(String(characters[index..<index + 3])))
        }
        return hashes.sorted()
    }

    public static func jaccard(_ a: Set<UInt32>, _ b: Set<UInt32>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    public static func senderKey(_ sender: String?) -> String? {
        guard let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !sender.isEmpty else {
            return nil
        }
        return SHA256.hash(data: Data(sender.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable across launches, unlike Swift's hashValue.
    private static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }

    // MARK: File

    private static func load(_ fileURL: URL) -> [CorrectionExample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CorrectionExample].self, from: data)) ?? []
    }

    /// Changes the saved examples in one step. The iPhone learns from History fixes
    /// this way; Karui for Mac replaces them with the iPhone's.
    public static func update(_ fileURL: URL, _ change: (inout [CorrectionExample]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var examples = load(fileURL)
        change(&examples)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try JSONEncoder().encode(examples).write(to: fileURL, options: options)
            NotificationCenter.default.post(name: didChange, object: nil)
        } catch {
            logger.error("Couldn’t save learned corrections: \(EnhancedLogging.describe(error), privacy: .public)")
        }
    }
}
