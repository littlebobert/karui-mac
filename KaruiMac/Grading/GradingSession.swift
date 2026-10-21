#if DEBUG
import Foundation
import KaruiSorting
import Observation

/// Developer builds: grading History by hand, for a golden set to score prompts
/// against. Items come from this Mac's own copy of History (the inbox, while the
/// iPhone's Show History on your Mac is on) and from the iPhone's Export History
/// (JSON Lines), which also says which items were fixed or changed. Each is shown
/// without Karui's category, reason, or confidence, so the grade isn't anchored to
/// what Karui said. Grades stay in Application Support/Karui/Grading on this Mac.
@MainActor
@Observable
final class GradingSession {
    enum Label: String, Codable, CaseIterable {
        // The iPhone's category raw values, so a grade compares with History as is.
        case important = "notifyNow"
        case neutral = "summary"
        case spam = "silence"
        /// Genuinely unclear: scored apart, not forced into a category.
        case unclear = "ambiguous"

        var title: String {
            switch self {
            case .important: "Important"
            case .neutral: "Neutral"
            case .spam: "Spam"
            case .unclear: "Unclear"
            }
        }

        static func title(forCategory category: String) -> String {
            Label(rawValue: category)?.title ?? category
        }
    }

    enum Queue: String, Codable, CaseIterable {
        /// Everything ungraded: the items whose category was changed first, as the hard
        /// cases, then the rest with the categories taking turns.
        case golden
        /// The past week's Neutral and Spam that no one fixed: an estimate of the
        /// misses that skimming History never catches.
        case spotCheck

        var title: String {
            switch self {
            case .golden: "Golden Set"
            case .spotCheck: "Spot Check"
            }
        }
    }

    /// One line of the iPhone's `HistoryExport`, or this Mac's copy of an item in the
    /// same shape. Only what grading reads; an export's line is kept as it came.
    struct ExportLine: Codable, Equatable {
        /// The iPhone's History ID; this Mac's copy doesn't have it.
        var id: UUID?
        var triagedAt: Date
        var source: String
        var sender: String?
        var title: String
        var subtitle: String?
        var body: String
        var recipients: String?
        var isTimeSensitive: Bool?
        var detectedLanguage: String?
        var category: String
        var reason: String?
        var decidedBy: String?
        var originalCategory: String?
        var triggers: [String]?
        /// What decided the category as it stands, as `ClassificationEngine` names it.
        /// Only exports have it: the iPhone doesn't send it with this Mac's copy.
        var engine: String?
        /// What made the first sort, before any second opinion or fix, and whether that
        /// was the rules only because the on-device model couldn't answer. From Karui
        /// 0.2.3's export; older exports have only `engine`.
        var firstEngine: String?
        var firstWasModelFallback: Bool?
    }

    enum Origin: String, Codable {
        case export
        case mac
    }

    struct Item: Identifiable, Equatable {
        let line: ExportLine
        let origin: Origin
        /// An export's line as it came; nil for this Mac's copy.
        let raw: Data?
        /// The same for an item's export line and this Mac's copy of it, which the
        /// iPhone sends with History's own title, body, and sort time: so an item is
        /// graded once whichever way it arrived.
        let id: String
        /// Its place in the stable shuffle; worked out once, since the queue sorts thousands.
        let order: UInt64

        init(line: ExportLine, origin: Origin, raw: Data?) {
            self.line = line
            self.origin = origin
            self.raw = raw
            id = "\(line.title)\u{1F}\(line.body)\u{1F}\(Int((line.triagedAt.timeIntervalSince1970 / 60).rounded(.down)))"
            order = GradingSession.order(id)
        }

        /// Whether the person fixed it, or anything changed its category: the hard cases.
        var wasRevised: Bool {
            line.originalCategory != nil || isFixedByPerson
        }

        var isFixedByPerson: Bool {
            (line.triggers ?? []).contains("correction")
        }

        /// Decided by the rules alone (VIPs, @mentions, codes, urgent terms), which no
        /// prompt changes: by the first sort, so a rules answer later fixed still counts,
        /// and a fallback the model should have given doesn't. An older export says only
        /// what decided the category as it stands, and its fallbacks read as rules.
        var isDecidedByRules: Bool {
            guard line.firstWasModelFallback != true else { return false }
            return (line.firstEngine ?? line.engine) == ClassificationEngine.deterministicRules.rawValue
        }
    }

    struct Grade: Codable, Equatable {
        /// The item's `id`.
        let id: String
        let label: Label
        let queue: Queue
        let gradedAt: Date
    }

    struct Tally: Equatable {
        var counts: [Label: Int] = [:]
        /// Graded items, Unclear aside, whose category in History matches the grade.
        var agreed = 0
        var compared = 0
    }

    static let spotCheckGoal = 20
    static let spotCheckWindow: TimeInterval = 7 * 24 * 60 * 60

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Karui/Grading", directoryHint: .isDirectory)
    }

    /// Imported from the iPhone's exports, kept on disk.
    private(set) var exportedItems: [String: Item] = [:]
    /// This Mac's copy of History, read again by `refreshMacHistory()`.
    private(set) var macItems: [String: Item] = [:]
    /// Both sources; where an item is in both, the export's line, which knows more.
    private(set) var items: [String: Item] = [:]
    /// The queues before grades and skips, worked out when the items change rather
    /// than on every keypress: this Mac's History alone is thousands of items.
    private var goldenOrder: [Item] = []
    /// Neutral and Spam no one fixed, of any age; `spotCheckWindow` applies on reading.
    private var spotCheckOrder: [Item] = []
    /// Items the Golden Set leaves out because the rules decided them.
    private(set) var ruleDecidedCount = 0
    /// Every grade in the order given; a later grade of the same item wins.
    private(set) var grades: [Grade] = []
    private var gradedIDs: Set<String> = []
    var queue: Queue = .golden {
        didSet { skipped = [] }
    }
    /// Skipped this session, in order: they go to the end of the queue.
    private(set) var skipped: [String] = []
    /// The item whose grade was just taken back, first in line again.
    private var restored: String?
    /// The grade just given, shown with what Karui said once it can't anchor anything.
    private(set) var lastGrade: Grade?
    var message: String?

    let folder: URL
    private let now: () -> Date
    private let macHistory: () -> [Item]

    init(
        folder: URL = defaultFolder,
        now: @escaping () -> Date = { Date() },
        macHistory: @escaping () -> [Item] = { [] }
    ) {
        self.folder = folder
        self.now = now
        self.macHistory = macHistory
        load()
        refreshMacHistory()
    }

    private var historyFile: URL { folder.appending(path: "history.jsonl") }
    private var gradesFile: URL { folder.appending(path: "grades.jsonl") }

    func refreshMacHistory() {
        macItems = Dictionary(macHistory().map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        rebuild()
    }

    private func rebuild() {
        items = macItems.merging(exportedItems) { _, exported in exported }
        let shuffled = items.values.sorted { $0.order < $1.order }
        // The golden set is for scoring prompts, so it leaves out what the rules decided.
        let modelDecided = shuffled.filter { !$0.isDecidedByRules }
        ruleDecidedCount = shuffled.count - modelDecided.count
        goldenOrder = modelDecided.filter(\.wasRevised) + Self.interleaved(modelDecided.filter { !$0.wasRevised })
        spotCheckOrder = shuffled.filter { !$0.isFixedByPerson && $0.line.category != Label.important.rawValue }
    }

    // MARK: Queue

    /// The next item, found without building the whole queue.
    var current: Item? {
        if restored != nil { return candidates(for: queue).first }
        let isOpen = openTest(for: queue)
        let skippedIDs = Set(skipped)
        if let next = order(for: queue).first(where: { isOpen($0) && !skippedIDs.contains($0.id) }) {
            return next
        }
        return skipped.lazy.compactMap { self.items[$0] }.first(where: isOpen)
    }

    var remaining: Int {
        let isOpen = openTest(for: queue)
        return order(for: queue).reduce(0) { $0 + (isOpen($1) ? 1 : 0) }
    }

    func candidates(for queue: Queue) -> [Item] {
        let isOpen = openTest(for: queue)
        let skippedIDs = Set(skipped)
        let open = order(for: queue).filter(isOpen)
        var result = open.filter { !skippedIDs.contains($0.id) }
            + skipped.compactMap { id in items[id] }.filter(isOpen)
        if let restored, let index = result.firstIndex(where: { $0.id == restored }) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    private func order(for queue: Queue) -> [Item] {
        switch queue {
        case .golden: goldenOrder
        case .spotCheck: spotCheckOrder
        }
    }

    /// Whether an item from `order(for:)` is still to grade: ungraded, and for a spot
    /// check, from the past week.
    private func openTest(for queue: Queue) -> (Item) -> Bool {
        let graded = gradedIDs
        let since = queue == .spotCheck ? now().addingTimeInterval(-Self.spotCheckWindow) : .distantPast
        return { !graded.contains($0.id) && $0.line.triagedAt >= since }
    }

    /// A stable shuffle: the same order on every launch, unrelated to time or source.
    nonisolated static func order(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Important, Neutral, and Spam taking turns, so a short session still sees all
    /// three however lopsided History is.
    static func interleaved(_ items: [Item]) -> [Item] {
        let categories = [Label.important, .neutral, .spam].map(\.rawValue)
        var groups = categories.map { category in items.filter { $0.line.category == category } }
        groups.append(items.filter { !categories.contains($0.line.category) })
        var result: [Item] = []
        var index = 0
        while result.count < items.count {
            for group in groups where index < group.count {
                result.append(group[index])
            }
            index += 1
        }
        return result
    }

    // MARK: Grading

    func grade(_ label: Label) {
        guard let item = current else { return }
        let grade = Grade(id: item.id, label: label, queue: queue, gradedAt: now())
        grades.append(grade)
        gradedIDs.insert(item.id)
        skipped.removeAll { $0 == item.id }
        restored = nil
        lastGrade = grade
        saveGrades()
    }

    func skip() {
        guard let item = current else { return }
        skipped.removeAll { $0 == item.id }
        skipped.append(item.id)
        restored = nil
    }

    /// Takes back the last grade; its item comes back first, in the queue it was graded in.
    func undo() {
        guard let grade = grades.popLast() else { return }
        gradedIDs = Set(grades.map(\.id))
        if queue != grade.queue { queue = grade.queue }
        skipped.removeAll { $0 == grade.id }
        restored = grade.id
        lastGrade = nil
        saveGrades()
    }

    var latestGrades: [String: Grade] {
        Dictionary(grades.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
    }

    func tally(queue: Queue? = nil, since: Date? = nil) -> Tally {
        let items = items
        var tally = Tally()
        for grade in latestGrades.values {
            if let queue, grade.queue != queue { continue }
            if let since, grade.gradedAt < since { continue }
            tally.counts[grade.label, default: 0] += 1
            guard grade.label != .unclear, let item = items[grade.id] else { continue }
            tally.compared += 1
            if item.line.category == grade.label.rawValue { tally.agreed += 1 }
        }
        return tally
    }

    /// Spot checks graded in the past week, toward `spotCheckGoal`.
    var spotCheckThisWeek: Tally {
        tally(queue: .spotCheck, since: now().addingTimeInterval(-Self.spotCheckWindow))
    }

    // MARK: Import and export

    /// Adds each export's lines; a line already here is replaced, since a later export
    /// carries later fixes. Grades are kept.
    @discardableResult
    func importHistory(from urls: [URL]) -> Int {
        let decoder = Self.decoder
        let before = Set(items.keys)
        var added = 0
        var unreadable = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                unreadable += 1
                continue
            }
            for raw in data.split(separator: 0x0A) where !raw.isEmpty {
                guard let line = try? decoder.decode(ExportLine.self, from: Data(raw)) else {
                    unreadable += 1
                    continue
                }
                let item = Item(line: line, origin: .export, raw: Data(raw))
                if !before.contains(item.id), exportedItems[item.id] == nil { added += 1 }
                exportedItems[item.id] = item
            }
        }
        rebuild()
        saveHistory()
        message = "Imported \(added) new item\(added == 1 ? "" : "s")"
            + (unreadable > 0 ? ", \(unreadable) unreadable" : "")
            + ". \(items.count) in all."
        return added
    }

    /// Every graded item as its export line, or this Mac's copy in the same shape, plus
    /// `origin`, `label`, `labelQueue`, and `gradedAt`, oldest grade first. Unclear ones
    /// are included, labeled `ambiguous`.
    func goldenSet() throws -> Data {
        let items = items
        let encoder = Self.encoder
        var data = Data()
        for grade in latestGrades.values.sorted(by: { $0.gradedAt < $1.gradedAt }) {
            guard let item = items[grade.id],
                  var object = try JSONSerialization.jsonObject(with: item.raw ?? encoder.encode(item.line)) as? [String: Any] else { continue }
            object["origin"] = item.origin.rawValue
            object["label"] = grade.label.rawValue
            object["labelQueue"] = grade.queue.rawValue
            object["gradedAt"] = ISO8601DateFormatter().string(from: grade.gradedAt)
            data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            data.append(0x0A)
        }
        return data
    }

    static func goldenSetFileName(now: Date = .now) -> String {
        "karui-golden-\(now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).jsonl"
    }

    // MARK: Files

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func load() {
        let decoder = Self.decoder
        if let data = try? Data(contentsOf: historyFile) {
            for raw in data.split(separator: 0x0A) where !raw.isEmpty {
                if let line = try? decoder.decode(ExportLine.self, from: Data(raw)) {
                    let item = Item(line: line, origin: .export, raw: Data(raw))
                    exportedItems[item.id] = item
                }
            }
        }
        if let data = try? Data(contentsOf: gradesFile) {
            grades = data.split(separator: 0x0A).compactMap { try? decoder.decode(Grade.self, from: Data($0)) }
            gradedIDs = Set(grades.map(\.id))
        }
    }

    private func saveHistory() {
        var data = Data()
        for item in exportedItems.values.sorted(by: { $0.line.triagedAt > $1.line.triagedAt }) {
            guard let raw = item.raw else { continue }
            data.append(raw)
            data.append(0x0A)
        }
        write(data, to: historyFile)
    }

    private func saveGrades() {
        let encoder = Self.encoder
        var data = Data()
        for grade in grades {
            guard let line = try? encoder.encode(grade) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        write(data, to: gradesFile)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            message = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
#endif
