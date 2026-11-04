import Foundation
import KaruiSorting

/// What one prompt got from Private Cloud Compute on one run.
public struct Outcome: Equatable, Sendable {
    /// Nil when the answer named no category the parser could find.
    public let category: TriageCategory?
    public let answer: String
    public let seconds: Double
    public let wasCached: Bool
}

/// One golden item under one prompt: its answers so far, run by run.
public struct ItemResult: Equatable, Sendable {
    public let item: GoldenItem
    public let index: Int
    public let prompt: String
    public var outcomes: [Outcome] = []

    /// The category most runs gave; a tie goes to the earliest run. Nil when no
    /// answer could be read.
    public var majority: TriageCategory? {
        let readable = outcomes.compactMap(\.category)
        guard let top = readable.map({ category in readable.filter { $0 == category }.count }).max() else { return nil }
        return readable.first { category in readable.filter { $0 == category }.count == top }
    }

    /// Readable runs that didn't all agree.
    public var flips: Bool {
        Set(outcomes.compactMap(\.category)).count > 1
    }
}

public struct VariantResult: Equatable, Sendable {
    public let template: PromptTemplate
    public var items: [ItemResult]
}

/// Sends each graded item's prompt, under each template, to Private Cloud Compute,
/// one run at a time across everything: if Apple's limit stops it partway, every
/// variant has the same runs to compare. Items graded Unclear aren't asked about.
/// Unchecked: its properties are constants, and a parallel run takes its own lock
/// around the cache and the shared tallies.
public final class Runner: @unchecked Sendable {
    public struct Progress: Sendable {
        public var cached = 0
        public var asked = 0
        public var failed = 0
        public var total = 0

        public init(cached: Int = 0, asked: Int = 0, failed: Int = 0, total: Int = 0) {
            self.cached = cached
            self.asked = asked
            self.failed = failed
            self.total = total
        }
    }

    let items: [GoldenItem]
    let policy: TriagePolicy
    let locale: Locale
    let runs: Int
    let cache: AnswerCache
    /// Which backend's answers, in the cache (`Backend.cacheNamespace`).
    let namespace: String?
    let ask: (String) -> (answer: String, seconds: Double)?
    let delay: TimeInterval
    let maxFailuresInARow: Int
    let report: (Progress) -> Void

    public init(
        items: [GoldenItem],
        policy: TriagePolicy,
        locale: Locale,
        runs: Int,
        cache: AnswerCache,
        namespace: String? = nil,
        delay: TimeInterval = 1,
        maxFailuresInARow: Int = 5,
        ask: @escaping (String) -> (answer: String, seconds: Double)?,
        report: @escaping (Progress) -> Void = { _ in }
    ) {
        self.items = items
        self.policy = policy
        self.locale = locale
        self.runs = runs
        self.cache = cache
        self.namespace = namespace
        self.delay = delay
        self.maxFailuresInARow = maxFailuresInARow
        self.ask = ask
        self.report = report
    }

    /// Every template's prompt for every graded item, rendered before anything is
    /// asked, so a mistake in a variant shows before any call is spent.
    public func prepare(_ templates: [PromptTemplate]) throws -> [VariantResult] {
        let graded = items.enumerated().filter { $0.element.labelCategory != nil }
        let sections = try graded.map { try PromptSections(item: $0.element, policy: policy, locale: locale) }
        return try templates.map { template in
            VariantResult(template: template, items: try zip(graded, sections).map { entry, sections in
                ItemResult(item: entry.element, index: entry.offset, prompt: try template.render(sections))
            })
        }
    }

    /// How many answers aren't cached yet.
    public func uncached(_ results: [VariantResult]) -> Int {
        results.reduce(0) { total, variant in
            total + variant.items.reduce(0) { sum, item in
                sum + (0..<runs).filter { cache.entry(prompt: item.prompt, run: $0, namespace: namespace) == nil }.count
            }
        }
    }

    /// Fills in the answers. Says how many came from the cache, were asked, and
    /// failed, and whether it stopped early because the Shortcut kept failing, as when
    /// Apple's limit is reached; what it got is cached.
    @discardableResult
    public func run(_ results: inout [VariantResult]) -> (progress: Progress, stoppedEarly: Bool) {
        var progress = Progress(total: results.reduce(0) { $0 + $1.items.count } * runs)
        var failuresInARow = 0
        for run in 0..<runs {
            for itemIndex in results.first?.items.indices ?? 0..<0 {
                for variantIndex in results.indices {
                    let prompt = results[variantIndex].items[itemIndex].prompt
                    let outcome: Outcome
                    if let entry = cache.entry(prompt: prompt, run: run, namespace: namespace) {
                        outcome = Self.outcome(answer: entry.answer, seconds: entry.seconds, wasCached: true)
                        progress.cached += 1
                    } else {
                        if progress.asked + progress.failed > 0, delay > 0 { Thread.sleep(forTimeInterval: delay) }
                        guard let answer = ask(prompt) else {
                            progress.failed += 1
                            failuresInARow += 1
                            report(progress)
                            if failuresInARow >= maxFailuresInARow { return (progress, true) }
                            continue
                        }
                        failuresInARow = 0
                        _ = try? cache.store(prompt: prompt, run: run, namespace: namespace, answer: answer.answer, seconds: answer.seconds)
                        outcome = Self.outcome(answer: answer.answer, seconds: answer.seconds, wasCached: false)
                        progress.asked += 1
                    }
                    results[variantIndex].items[itemIndex].outcomes.append(outcome)
                    report(progress)
                }
            }
        }
        return (progress, false)
    }

    /// As `run`, with up to `parallel` answers being asked at once, for an API that
    /// takes them. The outcomes land in the order `run` gives them. Asking stops once
    /// `maxFailuresInARow` fail in a row, though requests already sent finish.
    @discardableResult
    public func run(_ results: inout [VariantResult], parallel: Int) -> (progress: Progress, stoppedEarly: Bool) {
        guard parallel > 1 else { return run(&results) }
        struct Slot: Hashable { let run: Int; let item: Int; let variant: Int }
        let state = ParallelState<Slot>(progress: Progress(total: results.reduce(0) { $0 + $1.items.count } * runs))
        var jobs: [(slot: Slot, prompt: String)] = []
        for run in 0..<runs {
            for itemIndex in results.first?.items.indices ?? 0..<0 {
                for variantIndex in results.indices {
                    let slot = Slot(run: run, item: itemIndex, variant: variantIndex)
                    let prompt = results[variantIndex].items[itemIndex].prompt
                    if let entry = cache.entry(prompt: prompt, run: run, namespace: namespace) {
                        state.outcomes[slot] = Self.outcome(answer: entry.answer, seconds: entry.seconds, wasCached: true)
                        state.progress.cached += 1
                    } else {
                        jobs.append((slot, prompt))
                    }
                }
            }
        }
        report(state.progress)
        let queued = jobs
        DispatchQueue.concurrentPerform(iterations: min(parallel, max(jobs.count, 1))) { _ in
            while true {
                state.lock.lock()
                guard !state.stopped, state.next < queued.count else {
                    state.lock.unlock()
                    return
                }
                let job = queued[state.next]
                state.next += 1
                state.lock.unlock()

                let answer = ask(job.prompt)

                state.lock.lock()
                if let answer {
                    state.failuresInARow = 0
                    _ = try? cache.store(prompt: job.prompt, run: job.slot.run, namespace: namespace, answer: answer.answer, seconds: answer.seconds)
                    state.outcomes[job.slot] = Self.outcome(answer: answer.answer, seconds: answer.seconds, wasCached: false)
                    state.progress.asked += 1
                } else {
                    state.progress.failed += 1
                    state.failuresInARow += 1
                    if state.failuresInARow >= maxFailuresInARow { state.stopped = true }
                }
                report(state.progress)
                state.lock.unlock()
            }
        }
        for run in 0..<runs {
            for itemIndex in results.first?.items.indices ?? 0..<0 {
                for variantIndex in results.indices {
                    if let outcome = state.outcomes[Slot(run: run, item: itemIndex, variant: variantIndex)] {
                        results[variantIndex].items[itemIndex].outcomes.append(outcome)
                    }
                }
            }
        }
        return (state.progress, state.stopped)
    }

    /// The answers already cached, asking nothing: to compare with a backend that
    /// isn't being asked now.
    public func fillFromCache(_ results: inout [VariantResult]) {
        for variantIndex in results.indices {
            for itemIndex in results[variantIndex].items.indices {
                let prompt = results[variantIndex].items[itemIndex].prompt
                results[variantIndex].items[itemIndex].outcomes = (0..<runs).compactMap { run in
                    cache.entry(prompt: prompt, run: run, namespace: namespace).map {
                        Self.outcome(answer: $0.answer, seconds: $0.seconds, wasCached: true)
                    }
                }
            }
        }
    }

    static func outcome(answer: String, seconds: Double, wasCached: Bool) -> Outcome {
        Outcome(category: SecondOpinionPrompt.parse(answer: answer)?.category, answer: answer, seconds: seconds, wasCached: wasCached)
    }
}

/// What the workers of a parallel run share, behind its lock.
final class ParallelState<Slot: Hashable>: @unchecked Sendable {
    let lock = NSLock()
    var next = 0
    var failuresInARow = 0
    var stopped = false
    var outcomes: [Slot: Outcome] = [:]
    var progress: Runner.Progress

    init(progress: Runner.Progress) {
        self.progress = progress
    }
}
