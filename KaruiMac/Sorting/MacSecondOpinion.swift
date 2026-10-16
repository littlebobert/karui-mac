import Foundation
import KaruiSorting

/// Second Opinion on the Mac: Karui for Mac can't use Private Cloud Compute itself
/// (its Developer ID profile can't carry the entitlement), so it runs the person's
/// own Shortcut, whose Use Model action asks it, with the same prompt the iPhone
/// sends. Follows the iPhone's Second Opinion setting and When to Ask, synced with
/// the rest of its settings.
enum MacSecondOpinion {
    static let defaultShortcutName = "Karui Second Opinion"
    /// The standard Shortcut: receive text, Use Model set to Private Cloud Compute,
    /// output the response.
    static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/5e5dadea36134e56ab3d7f372eedd747")!
    static let deadline: Duration = .seconds(30)

    /// As the iPhone decides: never what the rules decided outright; with Before
    /// Alerting, every answer from the model; otherwise only what the rules sorted for it.
    static func shouldAsk(about result: TriageResult, policy: TriagePolicy) -> Bool {
        guard policy.secondOpinionEnabled else { return false }
        if policy.secondOpinionMode.asksAboutEveryModelAnswer {
            return result.engine == .onDeviceModel || result.isModelFallback
        }
        return result.isModelFallback && result.category != .notifyNow
    }

    /// Whether the person has made the Shortcut.
    static func isInstalled(name: String) async -> Bool {
        guard let output = await run(["list"], deadline: .seconds(10)) else { return false }
        return output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }

    /// The answer, read the way the iPhone reads it, with the rules applied after a
    /// model's answer there applied here too. Nil when the Shortcut is missing, fails,
    /// or answers nothing readable.
    static func ask(
        about notification: NotificationInput,
        policy: TriagePolicy,
        shortcutName: String,
        environment: SortingEnvironment
    ) async -> TriageResult? {
        let prompt = SecondOpinionPrompt.prompt(for: notification, policy: policy, correspondentMatch: environment.correspondentMatch)
        let folder = FileManager.default.temporaryDirectory.appending(path: "karui-second-opinion-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "prompt.txt")
        let output = folder.appending(path: "answer.txt")
        guard (try? Data(prompt.utf8).write(to: input)) != nil else { return nil }
        let start = ContinuousClock.now
        guard await run(["run", shortcutName, "--input-path", input.path, "--output-path", output.path], deadline: deadline) != nil,
              let answer = try? String(contentsOf: output, encoding: .utf8),
              let parsed = SecondOpinionPrompt.parse(answer: answer) else {
            SafeDiagnosticLog.shared.record("second opinion: the Shortcut gave no readable answer")
            return nil
        }
        let elapsed = start.duration(to: .now)
        var result = TriageResult(
            category: parsed.category,
            confidence: parsed.confidence,
            reason: parsed.reason,
            engine: .privateCloudCompute,
            engineDetail: "Second opinion from Private Cloud Compute, asked by Karui for Mac’s Shortcut."
        )
        result.tags = parsed.tags
        result.modelDuration = TimeInterval(elapsed.components.seconds)
        result = SavedContacts.applying(to: result, for: notification, policy: policy)
        result = KnownCorrespondents.applying(to: result, for: notification, policy: policy, match: environment.correspondentMatch)
        result = QuietApps.applying(to: result, for: notification, policy: policy)
        result = environment.applyingCorrections(result, notification, policy)
        SafeDiagnosticLog.shared.record("second opinion: \(result.category.rawValue) in \(elapsed)")
        return result
    }

    /// Runs `/usr/bin/shortcuts`, returning its output, or nil when it fails or runs
    /// past the deadline.
    private static func run(_ arguments: [String], deadline: Duration) async -> String? {
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
        let finished = await ModelDeadline.value(within: deadline) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                }
            }
        }
        guard let finished else {
            process.terminate()
            return nil
        }
        return finished
    }
}
