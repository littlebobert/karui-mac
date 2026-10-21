import Foundation

/// Asks Private Cloud Compute through the person's Shortcut, the way Karui for Mac's
/// `MacSecondOpinion` does: the prompt goes in as a file, Use Model answers, and the
/// answer comes back as a file.
public struct ShortcutClient: Sendable {
    public let name: String
    public let deadline: TimeInterval

    public init(name: String = "Karui Second Opinion", deadline: TimeInterval = 30) {
        self.name = name
        self.deadline = deadline
    }

    public func isInstalled() -> Bool {
        guard let output = Self.run(["list"], deadline: 10) else { return false }
        return output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }

    /// The answer's text and how long it took; nil when the Shortcut failed, ran past
    /// the deadline, or answered nothing.
    public func ask(_ prompt: String) -> (answer: String, seconds: Double)? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "karui-eval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "prompt.txt")
        let output = folder.appending(path: "answer.txt")
        guard (try? Data(prompt.utf8).write(to: input)) != nil else { return nil }
        let start = Date()
        guard Self.run(["run", name, "--input-path", input.path, "--output-path", output.path], deadline: deadline) != nil,
              let answer = try? String(contentsOf: output, encoding: .utf8),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (answer, Date().timeIntervalSince(start))
    }

    /// Runs `/usr/bin/shortcuts`, returning its output, or nil when it fails or runs
    /// past the deadline.
    private static func run(_ arguments: [String], deadline: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let end = Date().addingTimeInterval(deadline)
        while process.isRunning {
            if Date() > end {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
