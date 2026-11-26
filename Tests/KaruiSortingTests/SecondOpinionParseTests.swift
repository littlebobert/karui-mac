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

    /// The interest line the Neutral Summary ranks by, kept to 1 through 5 and never
    /// read as the reason or the confidence.
    func testReadsTheInterestLine() throws {
        let answer = try XCTUnwrap(SecondOpinionPrompt.parse(answer: """
        Category: Neutral
        Confidence: 0.8
        Interest: 4/5
        Reason: A shipping update for the user's own order.
        Tags: delivery, 配達
        """))
        XCTAssertEqual(answer.interest, 4)
        XCTAssertEqual(answer.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(answer.reason, "A shipping update for the user's own order.")
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: "Category: Neutral\nInterest: 9")?.interest, 5)
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: "カテゴリ: 普通\n関心度: 2")?.interest, 2)
        XCTAssertNil(SecondOpinionPrompt.parse(answer: "Category: Neutral\nReason: Nothing to do.")?.interest)
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: #"{"category": "Spam", "interest": 1}"#)?.interest, 1)
    }

    func testThePromptAsksForInterest() {
        let prompt = SecondOpinionPrompt.prompt(
            for: NotificationInput(source: "Mail", title: "Order shipped", body: "Your order is on its way."),
            policy: .standard,
            correspondentMatch: { _ in nil }
        )
        XCTAssertTrue(prompt.contains("Interest: a whole number from 1 through 5"))
    }
}
