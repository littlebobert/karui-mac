import FoundationModels
import XCTest
@testable import KaruiSorting

final class RateLimitResetDateTests: XCTestCase {
    /// iOS 27's error for a rate limit says when it ends; anything else says nothing.
    func testTheResetDateComesFromTheRateLimitError() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("LanguageModelError is iOS 27 and macOS 27") }
        let resets = Date(timeIntervalSince1970: 1_792_000_000)
        let limited = LanguageModelError.rateLimited(.init(resetDate: resets, debugDescription: "rate limited"))
        XCTAssertEqual(FoundationModelClassifier.rateLimitResetDate(of: limited), resets)
        let undated = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "rate limited"))
        XCTAssertNil(FoundationModelClassifier.rateLimitResetDate(of: undated))
        XCTAssertNil(FoundationModelClassifier.rateLimitResetDate(of: CancellationError()))
    }

    /// A check that rewrites the result keeps the fallback's reset date with it.
    func testARewrittenResultKeepsTheResetDate() {
        var policy = TriagePolicy.standard
        policy.userNames = "Justin"
        var fallback = TriageResult(category: .notifyNow, confidence: 0.6, reason: "", engine: .deterministicRules)
        fallback.isModelFallback = true
        fallback.rateLimitResetDate = Date(timeIntervalSince1970: 1_792_000_000)
        let checked = AddressedElsewhereCheck.applying(
            to: fallback,
            for: NotificationInput(source: "Slack", title: "#sales", body: "@Bob can you send me that report?"),
            policy: policy
        )
        XCTAssertEqual(checked.category, .summary)
        XCTAssertEqual(checked.rateLimitResetDate, fallback.rateLimitResetDate)
        XCTAssertTrue(checked.isModelFallback)
    }
}
