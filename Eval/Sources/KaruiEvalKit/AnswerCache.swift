import CryptoKit
import Foundation

/// Every answer Private Cloud Compute gave, by the exact prompt and which run it
/// was, so a rerun asks only about prompts that changed and a run cut short by a
/// rate limit picks up where it stopped. An answer that couldn't be read is kept
/// too: it's what that prompt got. A Shortcut that failed or timed out isn't, so
/// it's asked again next time. One JSON line per answer, appended as it comes.
public final class AnswerCache {
    public struct Entry: Codable, Equatable, Sendable {
        public let key: String
        public let answer: String
        public let seconds: Double
        public let askedAt: Date
    }

    public let url: URL
    private var entries: [String: Entry] = [:]

    public init(url: URL) throws {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(Entry.self, from: Data(line)) { entries[entry.key] = entry }
            }
        }
    }

    public var count: Int { entries.count }

    public static func key(prompt: String, run: Int) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined() + "#\(run)"
    }

    public func entry(prompt: String, run: Int) -> Entry? {
        entries[Self.key(prompt: prompt, run: run)]
    }

    @discardableResult
    public func store(prompt: String, run: Int, answer: String, seconds: Double, askedAt: Date = .now) throws -> Entry {
        let entry = Entry(key: Self.key(prompt: prompt, run: run), answer: answer, seconds: seconds, askedAt: askedAt)
        entries[entry.key] = entry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        return entry
    }
}
