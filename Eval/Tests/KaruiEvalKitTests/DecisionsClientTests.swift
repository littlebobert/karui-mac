import Foundation
import KaruiSorting
import XCTest
@testable import KaruiEvalKit

/// The Decisions API answers with a choice and probabilities, not text; they're
/// written back as answer lines the Second Opinion parser reads.
final class DecisionsClientTests: XCTestCase {
    func testAChoiceBecomesAnswerLinesWithItsProbabilities() throws {
        let reply = Data("""
        {"answers":[{"type":"choice","name":"category","choice":"Important","confidence":0.82,
          "probabilities":[{"value":"Important","probability":0.88},{"value":"Neutral","probability":0.12},{"value":"Spam","probability":0}]}],
         "model":"gpt-6-luna"}
        """.utf8)
        let answer = try XCTUnwrap(DecisionsClient.answer(from: reply))
        XCTAssertEqual(answer, "Category: Important\nConfidence: 0.820\nProbabilities: Important=0.8800 Neutral=0.1200 Spam=0.0000")
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: answer)?.category, .notifyNow)
    }

    func testARefusalIsKeptAsANote() {
        let reply = Data(#"{"answers":[{"type":"refusal","name":"category"}]}"#.utf8)
        XCTAssertEqual(DecisionsClient.answer(from: reply), "[Decisions declined]")
    }

    func testOnlyTheGatewayAsksForZeroRetention() {
        let gateway = DecisionsClient.body(model: "openai/gpt-6-luna-decisions", prompt: "p", zeroRetention: true)
        XCTAssertEqual((gateway["providerOptions"] as? [String: [String: Bool]])?["gateway"]?["zeroDataRetention"], true)
        XCTAssertNil(DecisionsClient.body(model: "gpt-6-luna", prompt: "p", zeroRetention: false)["providerOptions"])
        let question = (gateway["questions"] as? [[String: Any]])?.first
        XCTAssertEqual((question?["choices"] as? [[String: String]])?.map { $0["value"] }, ["Important", "Neutral", "Spam"])
    }
}
