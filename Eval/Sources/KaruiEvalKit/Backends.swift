import Foundation
import FoundationModels

/// Where a prompt is sent. Private Cloud Compute is the one that counts; the others
/// stand in for it where Apple's limit makes it slow to ask, and are only worth
/// using once `agree` shows they answer as it does.
public enum Backend: Sendable {
    case pcc(ShortcutClient)
    case ollama(OllamaClient)
    case onDevice(OnDeviceClient)
    case claude(ClaudeClient)
    /// Answers from outside the tool, such as from Claude, brought in with
    /// `import-answers`; never asked from here.
    case external(String)

    public var name: String {
        switch self {
        case .pcc(let client): "Private Cloud Compute (Shortcut “\(client.name)”)"
        case .ollama(let client): "Ollama \(client.model)"
        case .onDevice: "Apple’s on-device model"
        case .claude(let client): "Claude API \(client.model), effort \(client.effort)"
        case .external(let name): name
        }
    }

    public var shortName: String {
        switch self {
        case .pcc: "PCC"
        case .ollama(let client): client.model
        case .onDevice: "on-device"
        case .claude(let client): client.model
        case .external(let name): name
        }
    }

    /// Kept apart in the cache: nil for Private Cloud Compute, whose answers were
    /// cached before there were other backends. The on-device model comes with the
    /// OS, so its answers are kept by OS version.
    public var cacheNamespace: String? {
        switch self {
        case .pcc: nil
        case .ollama(let client): "ollama:\(client.model)"
        case .onDevice: "on-device:\(ProcessInfo.processInfo.operatingSystemVersionString)"
        case .claude(let client): "claude:\(client.model):\(client.effort)"
        case .external(let name): "external:\(name)"
        }
    }

    public func check() throws {
        switch self {
        case .pcc(let client):
            guard client.isInstalled() else {
                throw EvalError("There's no Shortcut named “\(client.name)”. Karui for Mac's Settings can add it, or pass --shortcut.")
            }
        case .ollama(let client): try client.check()
        case .onDevice(let client): try client.check()
        case .claude(let client): try client.check()
        case .external: return
        }
    }

    public func ask(_ prompt: String) -> (answer: String, seconds: Double)? {
        switch self {
        case .pcc(let client): client.ask(prompt)
        case .ollama(let client): client.ask(prompt)
        case .onDevice(let client): client.ask(prompt)
        case .claude(let client): client.ask(prompt)
        case .external: nil
        }
    }
}

/// A model run by Ollama on this Mac, sent the prompt as it is.
public struct OllamaClient: Sendable {
    public let model: String
    public let host: URL
    public let deadline: TimeInterval

    public init(model: String, host: URL = URL(string: "http://localhost:11434")!, deadline: TimeInterval = 300) {
        self.model = model
        self.host = host
        self.deadline = deadline
    }

    public func check() throws {
        guard let data = Self.send(URLRequest(url: host.appending(path: "api/tags")), deadline: 5) else {
            throw EvalError("Ollama isn't answering at \(host.absoluteString). Start it with `ollama serve`.")
        }
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let names = (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        guard names.contains(model) || names.contains("\(model):latest") else {
            throw EvalError("Ollama doesn't have \(model). Installed: \(names.joined(separator: ", ")). `ollama pull \(model)` adds it.")
        }
    }

    public func ask(_ prompt: String) -> (answer: String, seconds: Double)? {
        var request = URLRequest(url: host.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false])
        let start = Date()
        struct Reply: Decodable { let response: String }
        guard let data = Self.send(request, deadline: deadline),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (reply.response, Date().timeIntervalSince(start))
    }

    private static func send(_ request: URLRequest, deadline: TimeInterval) -> Data? {
        var request = request
        request.timeoutInterval = deadline
        let box = ResultBox<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.value = data }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }
}

/// Apple's on-device model on this Mac, sent the Second Opinion prompt as one
/// message with no instructions of its own: the same text Private Cloud Compute
/// gets. (Karui's own on-device sort is something else, its instructions as the
/// session's with structured output.)
public struct OnDeviceClient: Sendable {
    public init() {}

    public func check() throws {
        switch SystemLanguageModel.default.availability {
        case .available: return
        case .unavailable(let reason): throw EvalError("Apple’s on-device model isn't available on this Mac: \(reason).")
        }
    }

    /// The answer, or for a refusal or a prompt too long, a note saying so that's
    /// kept as an unreadable answer: asking again would get the same. Nil only for
    /// what may pass, such as the model's own rate limit.
    public func ask(_ prompt: String) -> (answer: String, seconds: Double)? {
        let box = ResultBox<(answer: String, seconds: Double)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        // Detached: the caller blocks the main thread until this is done.
        Task.detached {
            do {
                let response = try await LanguageModelSession().respond(to: prompt)
                box.value = (response.content, Date().timeIntervalSince(start))
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .rateLimited, .concurrentRequests, .assetsUnavailable: break
                default: box.value = ("[on-device model error: \(error)]", Date().timeIntervalSince(start))
                }
            } catch {}
            done.signal()
        }
        done.wait()
        return box.value
    }
}

/// Claude through the Messages API, sent the prompt as the one user message, with
/// your own credentials: `ANTHROPIC_API_KEY`, or an OAuth token in
/// `ANTHROPIC_AUTH_TOKEN`. There's no Swift SDK, so this is the API's plain HTTP.
public struct ClaudeClient: Sendable {
    public let model: String
    /// Thinking can't be turned off on current models, and sampling settings such as
    /// temperature are refused; effort is how much it thinks.
    public let effort: String
    public let deadline: TimeInterval

    public init(model: String = "claude-opus-5-5", effort: String = "medium", deadline: TimeInterval = 120) {
        self.model = model
        self.effort = effort
        self.deadline = deadline
    }

    private enum Credential {
        case apiKey(String)
        case oauthToken(String)
    }

    private var credential: Credential? {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty { return .apiKey(key) }
        if let token = environment["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty { return .oauthToken(token) }
        return nil
    }

    public func check() throws {
        guard ["low", "medium", "high", "xhigh", "max"].contains(effort) else {
            throw EvalError("--effort is low, medium, high, xhigh, or max.")
        }
        guard credential != nil else {
            throw EvalError("No Claude credentials: export ANTHROPIC_API_KEY (from platform.claude.com) in the terminal that runs this.")
        }
    }

    /// The answer's text. A refusal is kept as a note, read as unreadable, since asking
    /// again would get the same; nil for what may pass (a rate limit, an overload, the
    /// network) and for a request the API turned down, whose reason is printed.
    public func ask(_ prompt: String) -> (answer: String, seconds: Double)? {
        guard let credential else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = deadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // A refusal is retried on the model the API picks for it, in the same call.
        var betas = ["server-side-fallback-2026-07-01"]
        switch credential {
        case .apiKey(let key): request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauthToken(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            betas.append("oauth-2025-04-20")
        }
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            // Covers the thinking as well as the few answer lines.
            "max_tokens": 16000,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let model: String?
            let content: [Block]
            let stop_reason: String?
        }
        let start = Date()
        for attempt in 0..<3 {
            let box = ResultBox<(Data?, HTTPURLResponse?)>((nil, nil))
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                box.value = (data, response as? HTTPURLResponse)
                done.signal()
            }.resume()
            done.wait()
            let (data, response) = box.value
            guard let data, let response else { return nil }
            switch response.statusCode {
            case 200:
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
                if let served = reply.model, served != model {
                    FileHandle.standardError.write(Data("\n\(served) answered in place of \(model) after a refusal.\n".utf8))
                }
                if reply.stop_reason == "refusal" {
                    return ("[Claude declined]", Date().timeIntervalSince(start))
                }
                let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (text, Date().timeIntervalSince(start))
            case 429, 500..., 408:
                // Wait as asked, then try again; past the third try it counts as failed.
                let wait = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(5 << attempt)
                Thread.sleep(forTimeInterval: min(wait, 60))
            default:
                FileHandle.standardError.write(Data("\nClaude API \(response.statusCode): \(String(decoding: data, as: UTF8.self))\n".utf8))
                return nil
            }
        }
        return nil
    }
}

final class ResultBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
