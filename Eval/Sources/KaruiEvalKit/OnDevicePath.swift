import Foundation
import FoundationModels
import KaruiSorting

/// Karui's own on-device sort, run on a golden set: `FoundationModelClassifier` itself,
/// with its instructions as the session's and its structured output, on Apple's
/// on-device model or on a model run by Ollama. Only the model's step: the rules
/// before and after it decided none of these items.
///
/// The eval gives it what it can't know: no calendar events, and nobody the person has
/// written to.
@available(macOS 27.0, *)
public struct OnDevicePath {
    public enum Model: Sendable {
        case apple
        case ollama(String)

        public var name: String {
            switch self {
            case .apple: "Apple’s on-device model, through Karui’s on-device sort"
            case .ollama(let model): "Ollama \(model), through Karui’s on-device sort"
            }
        }

        public var cacheNamespace: String {
            switch self {
            case .apple: "on-device-path:apple"
            // "ordered": answers from before the schema kept its order aren't reused.
            case .ollama(let model): "on-device-path:ollama:\(model):ordered"
            }
        }
    }

    public static let template = PromptTemplate(
        name: "on-device",
        text: "",
        description: "Karui’s on-device sort: its rules as the session’s instructions, the policy and notification as the prompt, and structured output."
    )

    /// What the calendar says when no event is related to the notification.
    static let noCalendarEvents = "No calendar events related to this notification."

    let classifier: FoundationModelClassifier
    let policy: TriagePolicy
    let locale: Locale

    public init(model: Model, policy: TriagePolicy, locale: Locale) {
        let environment = SortingEnvironment(
            calendarContext: { _ in Self.noCalendarEvents },
            correspondentMatch: { _ in nil },
            applyingCorrections: { result, _, _ in result },
            conditions: { ("eval", "Mac") }
        )
        switch model {
        case .apple:
            classifier = FoundationModelClassifier(environment: environment)
        case .ollama(let name):
            classifier = FoundationModelClassifier(environment: environment) { instructions in
                LanguageModelSession(model: OllamaLanguageModel(name: name), instructions: instructions)
            }
        }
        self.policy = policy
        self.locale = locale
    }

    /// Each graded item with the text the model is given, which is also its cache key.
    public func prepare(_ items: [GoldenItem]) -> (results: [VariantResult], itemsByPrompt: [String: GoldenItem]) {
        var itemsByPrompt: [String: GoldenItem] = [:]
        let results = items.enumerated().filter { $0.element.labelCategory != nil }.map { index, item in
            let input = classifier.modelInput(for: item.notification, policy: policy, now: item.triagedAt, locale: locale)
            let prompt = "[Karui on-device sort]\n\(input.instructions)\n\n\(input.prompt)"
            itemsByPrompt[prompt] = item
            return ItemResult(item: item, index: index, prompt: prompt)
        }
        return ([VariantResult(template: Self.template, items: results)], itemsByPrompt)
    }

    /// The classifier's decision as answer lines the report reads. A failure or a
    /// timeout is kept as an unreadable answer, as it would leave the item to the rules
    /// in Karui; a rate limit isn't kept, since it passes.
    public func ask(_ item: GoldenItem) -> (answer: String, seconds: Double)? {
        let box = ResultBox<(answer: String, seconds: Double)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        let classifier = classifier
        let policy = policy
        let locale = locale
        // Detached: the caller blocks this thread until it's done.
        Task.detached {
            let result = await classifier.modelDecision(for: item.notification, policy: policy, now: item.triagedAt, locale: locale)
            let seconds = result.modelDuration ?? Date().timeIntervalSince(start)
            if result.rateLimitResetDate != nil {
                box.value = nil
            } else if result.engine != .onDeviceModel {
                box.value = ("[no decision: \(result.engineDetail ?? result.reason)]", seconds)
            } else {
                box.value = (Self.answer(result), seconds)
            }
            done.signal()
        }
        done.wait()
        return box.value
    }

    static func answer(_ result: TriageResult) -> String {
        let category = switch result.category {
        case .notifyNow: "Important"
        case .summary: "Neutral"
        case .silence: "Spam"
        }
        return """
        Category: \(category)
        Confidence: \(result.confidence)
        Reason: \(result.reason)
        Interest: \(result.interest.map(String.init) ?? "-")
        """
    }
}

/// A model run by Ollama, as Foundation Models runs a model of your own: Karui's
/// session sends it the transcript and the output's schema, and decodes its JSON.
@available(macOS 27.0, *)
public struct OllamaLanguageModel: LanguageModel {
    public typealias Executor = OllamaExecutor

    public let name: String
    public let host: URL

    public init(name: String, host: URL = URL(string: "http://localhost:11434")!) {
        self.name = name
        self.host = host
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    public var executorConfiguration: OllamaExecutor.Configuration { .init(host: host) }
}

@available(macOS 27.0, *)
public struct OllamaExecutor: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        public let host: URL
    }
    public typealias Model = OllamaLanguageModel

    let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OllamaLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let body = try Self.body(model: model.name, transcript: request.transcript, schema: request.schema)
        var urlRequest = URLRequest(url: configuration.host.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EvalError("Ollama answered \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data, as: UTF8.self))")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        await channel.send(.response(action: .appendText(reply.message.content, tokenCount: reply.eval_count ?? 0)))
        await channel.send(.response(action: .updateUsage(
            input: .init(totalTokenCount: reply.prompt_eval_count ?? 0, cachedTokenCount: 0),
            output: .init(totalTokenCount: reply.eval_count ?? 0, reasoningTokenCount: 0)
        )))
    }

    /// The chat request. Ollama generates an object's fields in the order its schema
    /// lists them, so the schema goes in with each object's properties in its declared
    /// order: the reason comes before the category it supports.
    static func body(model: String, transcript: Transcript, schema: GenerationSchema?) throws -> Data {
        var messages: [[String: String]] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions): messages.append(["role": "system", "content": text(instructions.segments)])
            case .prompt(let prompt): messages.append(["role": "user", "content": text(prompt.segments)])
            case .response(let response): messages.append(["role": "assistant", "content": text(response.segments)])
            default: break
            }
        }
        // Apple's on-device model has 8,192 tokens; Ollama would give 4,096, and cut
        // the start, the rules, off a longer prompt.
        let base = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": false, "think": false, "options": ["num_ctx": 8192]
        ] as [String: Any])
        guard let schema else { return base }
        let schemaJSON = try ordered(JSONEncoder().encode(schema))
        // `{…}` becomes `{…,"format":<schema>}`.
        return base.dropLast() + Data(",\"format\":".utf8) + schemaJSON + Data("}".utf8)
    }

    /// The schema with each object's properties in its `x-order`. Foundation Models
    /// encodes `properties` as a dictionary, in a different order in each process, and
    /// keeps the declared order only in `x-order`, which Ollama ignores.
    static func ordered(_ schema: Data) throws -> Data {
        Data(json(try JSONSerialization.jsonObject(with: schema)).utf8)
    }

    private static func json(_ value: Any) -> String {
        switch value {
        case let object as [String: Any]:
            let order = object["x-order"] as? [String] ?? []
            return "{" + object.keys.sorted().map { key in
                guard key == "properties", let properties = object[key] as? [String: Any] else {
                    return json(key) + ":" + json(object[key]!)
                }
                let names = order.filter { properties[$0] != nil } + properties.keys.filter { !order.contains($0) }.sorted()
                return json(key) + ":{" + names.map { json($0) + ":" + json(properties[$0]!) }.joined(separator: ",") + "}"
            }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(json).joined(separator: ",") + "]"
        default:
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined(separator: "\n")
    }
}
