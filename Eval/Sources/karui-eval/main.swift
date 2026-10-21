import Foundation
import KaruiEvalKit
import KaruiSorting

let usage = """
Usage:
  karui-eval run --golden FILE [--variant FILE]... [options]
      Runs every graded item through the shipping Second Opinion prompt and each
      variant (default: every .txt in ./variants), and writes a report.
      --runs N            Answers per item and prompt (default 3)
      --limit N           Only the first N items, to try a variant cheaply
      --dry-run           Count what would be asked, and ask nothing
      --delay SECONDS     Pause between calls to the Shortcut (default 1)
      --shortcut NAME     Default “Karui Second Opinion”
      --settings FILE     The iPhone's sorting settings (default: Karui for Mac's copy)
      --locale ID         The iPhone's locale, for the reason's language (default: this Mac's)
      --cache FILE        Default ~/Library/Application Support/Karui/Grading/eval-cache.jsonl
      --out DIR           Default a dated folder in ~/Library/Application Support/Karui/Grading/eval-reports
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
        let flagNames: Set<String> = ["--expanded", "--dry-run", "--help"]
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

func golden(_ arguments: Arguments) throws -> (URL, [GoldenItem]) {
    guard let url = arguments.url("--golden") else { throw EvalError("--golden is needed: the file from Grade History's Export Golden Set.") }
    let items = try GoldenItem.load(from: url)
    guard !items.isEmpty else { throw EvalError("\(url.lastPathComponent) has no items.") }
    return (url, items)
}

func templates(_ arguments: Arguments) throws -> [PromptTemplate] {
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

func run(_ arguments: Arguments) throws {
    let (goldenURL, items) = try golden(arguments)
    let limited = Array(items.prefix(try arguments.int("--limit", default: items.count)))
    let runs = try arguments.int("--runs", default: 3)
    let templates = try templates(arguments)
    let client = ShortcutClient(name: arguments.value("--shortcut") ?? "Karui Second Opinion")
    let cache = try AnswerCache(url: arguments.url("--cache") ?? grading.appending(path: "eval-cache.jsonl"))
    let delay = arguments.value("--delay").flatMap(Double.init) ?? 1
    let runner = Runner(
        items: limited, policy: try policy(arguments), locale: locale(arguments), runs: runs, cache: cache, delay: delay,
        ask: client.ask,
        report: { progress in
            let done = progress.cached + progress.asked + progress.failed
            FileHandle.standardError.write(Data("\r\(done)/\(progress.total) answers: \(progress.cached) cached, \(progress.asked) asked, \(progress.failed) failed   ".utf8))
        }
    )
    var results = try runner.prepare(templates)
    let unclear = limited.filter { $0.labelCategory == nil }.count
    let toAsk = runner.uncached(results)
    print("\(limited.count - unclear) graded items × \(templates.count) prompts (\(templates.map(\.name).joined(separator: ", "))) × \(runs) runs: \(toAsk) to ask, the rest cached.")
    if arguments.flags.contains("--dry-run") { return }
    if toAsk > 0 {
        guard client.isInstalled() else {
            throw EvalError("There's no Shortcut named “\(client.name)”. Karui for Mac's Settings can add it, or pass --shortcut.")
        }
    }
    let (progress, stoppedEarly) = runner.run(&results)
    printError("")
    let context = ReportWriter.Context(
        goldenFile: goldenURL.lastPathComponent, itemCount: limited.count, unclearCount: unclear, runs: runs,
        shortcut: client.name, progress: progress, stoppedEarly: stoppedEarly
    )
    let markdown = ReportWriter.markdown(results, context: context)
    let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
    let out = arguments.url("--out") ?? grading.appending(path: "eval-reports/\(stamp)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try Data(markdown.utf8).write(to: out.appending(path: "report.md"))
    try ReportWriter.jsonLines(results).write(to: out.appending(path: "results.jsonl"))
    print(markdown)
    print("Written to \(out.path)")
}

func template(_ arguments: Arguments) throws {
    let (_, items) = try golden(arguments)
    let sections = try PromptSections(item: items[0], policy: try policy(arguments), locale: locale(arguments))
    print(PromptTemplate.starter(sections: sections, expanded: arguments.flags.contains("--expanded")))
}

func prompt(_ arguments: Arguments) throws {
    let (_, items) = try golden(arguments)
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
        case "template": try template(arguments)
        case "prompt": try prompt(arguments)
        default: throw EvalError(usage)
        }
    }
} catch {
    printError("\(error)")
    exit(1)
}
