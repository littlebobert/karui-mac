import Foundation
import KaruiEvalKit
import KaruiSorting

let usage = """
Usage:
  karui-eval run --golden FILE [--variant FILE]... [--shipping-only] [options]
      Runs every graded item through the shipping Second Opinion prompt and each
      variant (default: every .txt in ./variants), and writes a report. Items the
      rules decided are left out, here and in every command: no prompt changes them.
      --shipping-only     Only the shipping prompt, no variants
      --runs N            Answers per item and prompt (default 3)
      --limit N           Only the first N items, to try a variant cheaply
      --dry-run           Count what would be asked, and ask nothing
      --delay SECONDS     Pause between calls (default 1 for PCC, 0 otherwise)
      --backend NAME      pcc (default), ollama, on-device, claude (with ANTHROPIC_API_KEY set),
                          or external (with --model,
                          answers brought in by import-answers)
      --model NAME        The Ollama model, such as gemma4:12b-mlx; for claude, default claude-opus-5-5
      --effort LEVEL      For claude: low, medium (default), high, xhigh, or max
      --shortcut NAME     For pcc; default “Karui Second Opinion”
      --settings FILE     The iPhone's sorting settings (default: Karui for Mac's copy)
      --locale ID         The iPhone's locale, for the reason's language (default: this Mac's)
      --cache FILE        Default ~/Library/Application Support/Karui/Grading/eval-cache.jsonl
      --out DIR           Default a dated folder in ~/Library/Application Support/Karui/Grading/eval-reports
  karui-eval agree --backend ollama|on-device [--model NAME] --golden FILE [options]
      Asks a stand-in backend the prompts Private Cloud Compute has answered (from
      the cache; PCC isn't asked), and reports how often the two agree. Takes run's
      options; --runs defaults to 1 for the stand-in.
  karui-eval export-prompts --model NAME --golden FILE --to DIR [--limit N] [--runs N]
      Writes each prompt the external backend NAME hasn't answered as DIR/0001.txt
      and so on, for a model outside this tool to answer in DIR/0001.answer.txt.
  karui-eval import-answers --model NAME --from DIR
      Caches the answers in DIR for the external backend NAME.
  karui-eval template [--expanded] --golden FILE [--settings FILE]
      Prints a starting point for a variant: the shipping prompt's parts as
      placeholders, or with --expanded, the instructions and answer lines written out.
  karui-eval prompt --golden FILE [--item N] [--variant FILE] [--settings FILE]
      Prints the prompt one item gets (default the first), to check a variant.
"""

struct Arguments {
    var command: String
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw EvalError(usage) }
        self.command = command
        var rest = arguments.dropFirst()
        let flagNames: Set<String> = ["--expanded", "--dry-run", "--shipping-only", "--help"]
        while let argument = rest.popFirst() {
            if flagNames.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--"), let value = rest.popFirst() {
                values[argument, default: []].append(value)
            } else {
                throw EvalError("Unexpected “\(argument)”.\n\n\(usage)")
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func url(_ name: String) -> URL? { value(name).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }
    func int(_ name: String, default fallback: Int) throws -> Int {
        guard let text = value(name) else { return fallback }
        guard let number = Int(text), number > 0 else { throw EvalError("\(name) takes a whole number above 0.") }
        return number
    }
}

let grading = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "Karui/Grading", directoryHint: .isDirectory)

func policy(_ arguments: Arguments) throws -> TriagePolicy {
    let url = arguments.url("--settings") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Karui/SortingSettings.json")
    guard let data = try? Data(contentsOf: url) else {
        throw EvalError("No sorting settings at \(url.path). Karui for Mac keeps them there while the iPhone's Show History on your Mac is on; or pass --settings.")
    }
    return try JSONDecoder().decode(TriagePolicy.self, from: data)
}

/// The golden set's items, less those the rules decided, and how many those were.
func golden(_ arguments: Arguments) throws -> (URL, [GoldenItem], ruleDecided: Int) {
    guard let url = arguments.url("--golden") else { throw EvalError("--golden is needed: the file from Grade History's Export Golden Set.") }
    guard FileManager.default.fileExists(atPath: url.path) else { throw EvalError("There's no golden set at \(url.path).") }
    let all = try GoldenItem.load(from: url)
    let items = all.filter { !$0.isDecidedByRules }
    guard !items.isEmpty else {
        throw EvalError(all.isEmpty ? "\(url.lastPathComponent) has no items." : "The rules decided every item in \(url.lastPathComponent), and no prompt changes those.")
    }
    return (url, items, all.count - items.count)
}

func templates(_ arguments: Arguments) throws -> [PromptTemplate] {
    if arguments.flags.contains("--shipping-only") {
        guard arguments.values["--variant"] == nil else { throw EvalError("--shipping-only and --variant don't go together.") }
        return [.shipping]
    }
    var urls = (arguments.values["--variant"] ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    if urls.isEmpty {
        let folder = URL(fileURLWithPath: "variants", isDirectory: true)
        urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    return [PromptTemplate.shipping] + (try urls.map(PromptTemplate.init(contentsOf:)))
}

func locale(_ arguments: Arguments) -> Locale {
    arguments.value("--locale").map(Locale.init(identifier:)) ?? .current
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func backend(_ arguments: Arguments) throws -> Backend {
    switch arguments.value("--backend") ?? "pcc" {
    case "pcc": return .pcc(ShortcutClient(name: arguments.value("--shortcut") ?? "Karui Second Opinion"))
    case "ollama":
        guard let model = arguments.value("--model") else { throw EvalError("--backend ollama needs --model, such as gemma4:e2b-mlx.") }
        return .ollama(OllamaClient(model: model))
    case "on-device": return .onDevice(OnDeviceClient())
    case "claude":
        return .claude(ClaudeClient(model: arguments.value("--model") ?? "claude-opus-5-5", effort: arguments.value("--effort") ?? "medium"))
    case "external":
        guard let name = arguments.value("--model") else { throw EvalError("--backend external needs --model, the name its answers were imported under.") }
        return .external(name)
    case let other: throw EvalError("No backend called “\(other)”: pcc, ollama, on-device, claude, or external.")
    }
}

/// A runner for one backend over the items and options given.
func runner(_ arguments: Arguments, items: [GoldenItem], backend: Backend, runs: Int, cache: AnswerCache) throws -> Runner {
    let defaultDelay: TimeInterval = if case .pcc = backend { 1 } else { 0 }
    return Runner(
        items: items, policy: try policy(arguments), locale: locale(arguments), runs: runs, cache: cache,
        namespace: backend.cacheNamespace, delay: arguments.value("--delay").flatMap(Double.init) ?? defaultDelay,
        ask: backend.ask,
        report: { progress in
            let done = progress.cached + progress.asked + progress.failed
            FileHandle.standardError.write(Data("\r\(done)/\(progress.total) answers: \(progress.cached) cached, \(progress.asked) asked, \(progress.failed) failed   ".utf8))
        }
    )
}

func cache(_ arguments: Arguments) throws -> AnswerCache {
    try AnswerCache(url: arguments.url("--cache") ?? grading.appending(path: "eval-cache.jsonl"))
}

func reportFolder(_ arguments: Arguments) throws -> URL {
    let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
    let out = arguments.url("--out") ?? grading.appending(path: "eval-reports/\(stamp)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    return out
}

func run(_ arguments: Arguments) throws {
    let (goldenURL, items, ruleDecided) = try golden(arguments)
    let limited = Array(items.prefix(try arguments.int("--limit", default: items.count)))
    let runs = try arguments.int("--runs", default: 3)
    let templates = try templates(arguments)
    let backend = try backend(arguments)
    let runner = try runner(arguments, items: limited, backend: backend, runs: runs, cache: try cache(arguments))
    var results = try runner.prepare(templates)
    let unclear = limited.filter { $0.labelCategory == nil }.count
    let toAsk = runner.uncached(results)
    if ruleDecided > 0 { print("Leaving out \(ruleDecided) items the rules decided.") }
    print("\(limited.count - unclear) graded items × \(templates.count) prompts (\(templates.map(\.name).joined(separator: ", "))) × \(runs) runs, \(backend.name): \(toAsk) to ask, the rest cached.")
    if arguments.flags.contains("--dry-run") { return }
    if toAsk > 0 { try backend.check() }
    let (progress, stoppedEarly) = runner.run(&results)
    printError("")
    let context = ReportWriter.Context(
        goldenFile: goldenURL.lastPathComponent, itemCount: limited.count, unclearCount: unclear, ruleDecidedCount: ruleDecided, runs: runs,
        backend: backend.name, progress: progress, stoppedEarly: stoppedEarly
    )
    let markdown = ReportWriter.markdown(results, context: context)
    let out = try reportFolder(arguments)
    try Data(markdown.utf8).write(to: out.appending(path: "report.md"))
    try ReportWriter.jsonLines(results).write(to: out.appending(path: "results.jsonl"))
    print(markdown)
    print("Written to \(out.path)")
}

func agree(_ arguments: Arguments) throws {
    let standIn = try backend(arguments)
    if case .pcc = standIn { throw EvalError("agree compares a stand-in with Private Cloud Compute: pass --backend ollama or on-device.") }
    let (goldenURL, items, _) = try golden(arguments)
    let limited = Array(items.prefix(try arguments.int("--limit", default: items.count)))
    let templates = try templates(arguments)
    let cache = try cache(arguments)
    // Private Cloud Compute's answers as cached, every run there is; nothing is asked.
    let pccRunner = try runner(arguments, items: limited, backend: .pcc(ShortcutClient()), runs: 3, cache: cache)
    var pcc = try pccRunner.prepare(templates)
    pccRunner.fillFromCache(&pcc)
    let answered = pcc.first?.items.filter { !$0.outcomes.isEmpty }.count ?? 0
    guard answered > 0 else {
        throw EvalError("Private Cloud Compute hasn't answered any of these prompts yet. Run `karui-eval run` with the same options first.")
    }
    let standInRunner = try runner(arguments, items: limited, backend: standIn, runs: try arguments.int("--runs", default: 1), cache: cache)
    var answers = try standInRunner.prepare(templates)
    let toAsk = standInRunner.uncached(answers)
    print("\(answered) items Private Cloud Compute answered × \(templates.count) prompts, \(standIn.name): \(toAsk) to ask, the rest cached.")
    if arguments.flags.contains("--dry-run") { return }
    if case .external = standIn {
        standInRunner.fillFromCache(&answers)
    } else {
        if toAsk > 0 { try standIn.check() }
        let (_, stoppedEarly) = standInRunner.run(&answers)
        printError("")
        if stoppedEarly { printError("\(standIn.name) kept failing, so this compares only what it answered.") }
    }
    let agreement = Agreement(pcc: pcc, standIn: answers)
    let markdown = agreement.markdown(standIn: standIn.shortName, goldenFile: goldenURL.lastPathComponent)
    let out = try reportFolder(arguments)
    try Data(markdown.utf8).write(to: out.appending(path: "agreement.md"))
    try ReportWriter.jsonLines(answers).write(to: out.appending(path: "results.jsonl"))
    print(markdown)
    print("Written to \(out.path)")
}

/// One prompt handed to a model outside this tool, and where its answer goes.
struct ExportedPrompt: Codable {
    let file: String
    let run: Int
    let prompt: String
}

func exportPrompts(_ arguments: Arguments) throws {
    guard let name = arguments.value("--model") else { throw EvalError("--model names the external backend, such as claude-opus.") }
    guard let folder = arguments.url("--to") else { throw EvalError("--to is the folder to write the prompts in.") }
    let (_, items, _) = try golden(arguments)
    let limited = Array(items.prefix(try arguments.int("--limit", default: items.count)))
    let backend = Backend.external(name)
    let runs = try arguments.int("--runs", default: 1)
    let cache = try cache(arguments)
    let runner = try runner(arguments, items: limited, backend: backend, runs: runs, cache: cache)
    let results = try runner.prepare(try templates(arguments))
    var exported: [ExportedPrompt] = []
    var seen = Set<String>()
    for variant in results {
        for item in variant.items {
            for run in 0..<runs where cache.entry(prompt: item.prompt, run: run, namespace: backend.cacheNamespace) == nil {
                guard seen.insert(AnswerCache.key(prompt: item.prompt, run: run)).inserted else { continue }
                exported.append(ExportedPrompt(file: String(format: "%04d", exported.count + 1), run: run, prompt: item.prompt))
            }
        }
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for prompt in exported {
        try Data(prompt.prompt.utf8).write(to: folder.appending(path: "\(prompt.file).txt"))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(exported).write(to: folder.appending(path: "prompts.json"))
    print("\(exported.count) prompts in \(folder.path), for \(name). Answer each NNNN.txt in NNNN.answer.txt, then import-answers.")
}

func importAnswers(_ arguments: Arguments) throws {
    guard let name = arguments.value("--model") else { throw EvalError("--model names the external backend the prompts were exported for.") }
    guard let folder = arguments.url("--from") else { throw EvalError("--from is the folder export-prompts wrote.") }
    let exported = try JSONDecoder().decode([ExportedPrompt].self, from: Data(contentsOf: folder.appending(path: "prompts.json")))
    let cache = try cache(arguments)
    var imported = 0
    var missing: [String] = []
    for prompt in exported {
        guard let answer = try? String(contentsOf: folder.appending(path: "\(prompt.file).answer.txt"), encoding: .utf8),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missing.append(prompt.file)
            continue
        }
        try cache.store(prompt: prompt.prompt, run: prompt.run, namespace: Backend.external(name).cacheNamespace, answer: answer, seconds: 0)
        imported += 1
    }
    print("Imported \(imported) answers for \(name)." + (missing.isEmpty ? "" : " No answer for \(missing.count): \(missing.prefix(10).joined(separator: ", "))\(missing.count > 10 ? "…" : "")."))
}

func template(_ arguments: Arguments) throws {
    let (_, items, _) = try golden(arguments)
    let sections = try PromptSections(item: items[0], policy: try policy(arguments), locale: locale(arguments))
    print(PromptTemplate.starter(sections: sections, expanded: arguments.flags.contains("--expanded")))
}

func prompt(_ arguments: Arguments) throws {
    let (_, items, _) = try golden(arguments)
    let index = try arguments.int("--item", default: 1) - 1
    guard items.indices.contains(index) else { throw EvalError("--item goes from 1 to \(items.count).") }
    let template = try arguments.url("--variant").map(PromptTemplate.init(contentsOf:)) ?? .shipping
    let sections = try PromptSections(item: items[index], policy: try policy(arguments), locale: locale(arguments))
    print(try template.render(sections))
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    if arguments.flags.contains("--help") {
        print(usage)
    } else {
        switch arguments.command {
        case "run": try run(arguments)
        case "agree": try agree(arguments)
        case "export-prompts": try exportPrompts(arguments)
        case "import-answers": try importAnswers(arguments)
        case "template": try template(arguments)
        case "prompt": try prompt(arguments)
        default: throw EvalError(usage)
        }
    }
} catch {
    printError("\(error)")
    exit(1)
}
