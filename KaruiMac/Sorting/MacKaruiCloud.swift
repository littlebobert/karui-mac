import Foundation
import KaruiSorting

/// Karui Cloud Sorting on the Mac: while it's on in Karui on the iPhone, the iPhone
/// sends its invite with its sorting settings, and this Mac asks Karui's backend
/// (github.com/littlebobert/karui-backend) about what a model sorts, as the iPhone
/// does (`KaruiCloud` in the iPhone app): OpenAI's decision model chooses the
/// category, with the same prompt as Private Cloud Compute. Answered, the Shortcut
/// isn't run; unanswered, the on-device answer stands.
enum MacKaruiCloud {
    static let baseURL = URL(string: "https://karui-backend.vercel.app")!
    /// More than the iPhone's 4 s: nothing here waits on a Shortcut's time budget.
    static let timeout: TimeInterval = 10

    /// As the iPhone decides: only what a model sorted, rate-limited fallbacks
    /// included; never what the rules decided outright, nor a silenced sender.
    static func shouldAsk(about result: TriageResult, notification: NotificationInput, policy: TriagePolicy) -> Bool {
        guard result.engine == .onDeviceModel || result.isModelFallback else { return false }
        return !policy.isSilencedSender(notification.sender, in: notification.source)
    }

    struct Decision: Equatable, Sendable {
        let category: TriageCategory
        /// The probability of the category chosen.
        let probability: Double
    }

    enum Outcome: Equatable, Sendable {
        case decided(Decision, seconds: TimeInterval)
        case refused
        /// Not answered, with why; the on-device answer stands.
        case failed(String)
    }

    /// Reads the backend's `{ category, probabilities }`, or `{ refused: true }`.
    static func outcome(from data: Data, status: Int, seconds: TimeInterval) -> Outcome {
        struct Reply: Decodable {
            let category: String?
            let probabilities: [String: Double]?
            let refused: Bool?
            let error: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .failed("HTTP \(status), unreadable") }
        guard status == 200 else { return .failed("HTTP \(status) \(reply.error ?? "")") }
        if reply.refused == true { return .refused }
        let categories: [String: TriageCategory] = ["Important": .notifyNow, "Neutral": .summary, "Spam": .silence]
        guard let name = reply.category, let category = categories[name] else { return .failed("unknown category") }
        return .decided(Decision(category: category, probability: reply.probabilities?[name] ?? 0), seconds: seconds)
    }

    static func ask(prompt: String, invite: String, session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: baseURL.appending(path: "api/sort"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(invite)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["prompt": prompt])
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return outcome(from: data, status: status, seconds: Date().timeIntervalSince(start))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The cloud's category over the on-device answer, as on the iPhone: the on-device
    /// reason and tags stay when the two agree; otherwise the reason says what the cloud
    /// decided. Then the same steps as any model answer on this Mac.
    static func result(
        applying decision: Decision,
        seconds: TimeInterval,
        to classifierResult: TriageResult,
        notification: NotificationInput,
        policy: TriagePolicy,
        environment: SortingEnvironment
    ) -> TriageResult {
        let agrees = classifierResult.engine == .onDeviceModel && !classifierResult.isModelFallback
            && classifierResult.category == decision.category
        let percent = Int((decision.probability * 100).rounded())
        var result = TriageResult(
            category: decision.category,
            confidence: decision.probability,
            reason: agrees
                ? classifierResult.reason
                : KaruiLocalization.formatted("Karui Cloud: %d%% likely %@.", percent, decision.category.title()),
            engine: .karuiCloud,
            engineDetail: "Sorted by Karui Cloud, asked by Karui for Mac.",
            interest: classifierResult.interest
        )
        if agrees {
            result.tags = classifierResult.tags
            result.deadline = classifierResult.deadline
        }
        result.modelDuration = seconds
        result = SavedContacts.applying(to: result, for: notification, policy: policy)
        result = KnownCorrespondents.applying(to: result, for: notification, policy: policy, match: environment.correspondentMatch)
        result = QuietApps.applying(to: result, for: notification, policy: policy)
        result = environment.applyingCorrections(result, notification, policy)
        result = SilencedSenders.applying(to: result, for: notification, policy: policy)
        return result
    }

    /// The cloud's result, or nil to keep the on-device answer.
    static func sort(
        _ notification: NotificationInput,
        classifierResult: TriageResult,
        policy: TriagePolicy,
        invite: String,
        environment: SortingEnvironment
    ) async -> TriageResult? {
        guard shouldAsk(about: classifierResult, notification: notification, policy: policy) else { return nil }
        let prompt = SecondOpinionPrompt.prompt(for: notification, policy: policy, correspondentMatch: environment.correspondentMatch)
        switch await ask(prompt: prompt, invite: invite) {
        case .decided(let decision, let seconds):
            SafeDiagnosticLog.shared.record("karui cloud: \(decision.category.rawValue) in \(String(format: "%.2f", seconds)) s")
            return result(applying: decision, seconds: seconds, to: classifierResult, notification: notification, policy: policy, environment: environment)
        case .refused:
            SafeDiagnosticLog.shared.record("karui cloud: declined; the on-device answer stands")
            return nil
        case .failed(let reason):
            SafeDiagnosticLog.shared.record("karui cloud: no answer (\(reason)); the on-device answer stands")
            return nil
        }
    }
}
