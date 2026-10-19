import XCTest
@testable import KaruiSorting

final class SecondOpinionParseTests: XCTestCase {
    /// The model sometimes answers in JSON; the reason must not be the opening brace.
    func testReadsAJSONAnswer() throws {
        let answer = try XCTUnwrap(SecondOpinionPrompt.parse(answer: """
        ```json
        {
          "category": "Spam",
          "confidence": 0.92,
          "reason": "A conference invitation sent to many customers."
        }
        ```
        """))
        XCTAssertEqual(answer.category, .silence)
        XCTAssertEqual(answer.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(answer.reason, "A conference invitation sent to many customers.")
    }

    func testJSONWithoutAReasonLeavesItEmpty() throws {
        let answer = try XCTUnwrap(SecondOpinionPrompt.parse(answer: #"{"Category": "Neutral", "Confidence": "80%"}"#))
        XCTAssertEqual(answer.category, .summary)
        XCTAssertEqual(answer.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(answer.reason, "")
    }

    /// JSON the parser can't read still falls back to the category word, with no
    /// brace or quote-only line taken as the reason.
    func testBrokenJSONNeverGivesABraceAsTheReason() throws {
        let answer = try XCTUnwrap(SecondOpinionPrompt.parse(answer: """
        {
          "category": "Spam",
        """))
        XCTAssertEqual(answer.category, .silence)
        XCTAssertFalse(answer.reason.contains("{"))
    }

    func testTheRequestedLinesStillWin() throws {
        let answer = try XCTUnwrap(SecondOpinionPrompt.parse(answer: "Category: Important\nConfidence: 0.9\nReason: Mom asks to call."))
        XCTAssertEqual(answer.category, .notifyNow)
        XCTAssertEqual(answer.reason, "Mom asks to call.")
    }
}
