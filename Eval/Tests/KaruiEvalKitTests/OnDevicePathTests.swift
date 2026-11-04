import Foundation
import FoundationModels
import KaruiSorting
import XCTest
@testable import KaruiEvalKit

@available(macOS 27.0, *)
@Generable
private struct Decision {
    @Guide(description: "Why")
    let reason: String
    @Guide(description: "What follows from the reason")
    let category: String
}

final class OnDevicePathTests: XCTestCase {
    func testTheRequestKeepsTheSchemaInOrderAndTheTranscriptAsMessages() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Needs macOS 27") }
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Rules"))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "A notification"))]))
        ])
        let body = try OllamaExecutor.body(model: "qwen3.5:4b", transcript: transcript, schema: Decision.generationSchema)
        let text = String(decoding: body, as: UTF8.self)
        let reason = try XCTUnwrap(text.range(of: "\"reason\""))
        let category = try XCTUnwrap(text.range(of: "\"category\""))
        XCTAssertLessThan(reason.lowerBound, category.lowerBound, text)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["think"] as? Bool, false)
        XCTAssertEqual((json["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Rules"], ["role": "user", "content": "A notification"]])
        XCTAssertNotNil(json["format"] as? [String: Any])
    }

    func testPropertiesFollowTheDeclaredOrderWhateverOrderTheyCameIn() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Needs macOS 27") }
        let schema = Data("""
        {"type":"object","x-order":["reason","category","confidence"],"properties":{"confidence":{"type":"number"},"category":{"type":"object","x-order":["b","a"],"properties":{"a":{"type":"boolean"},"b":{"type":"string","enum":["Important","Neutral"]}}},"reason":{"type":"string"}},"required":["reason","category","confidence"]}
        """.utf8)
        let text = String(decoding: try OllamaExecutor.ordered(schema), as: UTF8.self)
        let positions = ["\"reason\"", "\"category\"", "\"confidence\"", "\"b\"", "\"a\""].map { text.range(of: $0)!.lowerBound }
        XCTAssertLessThan(positions[0], positions[1], text)
        XCTAssertLessThan(positions[1], positions[2], text)
        XCTAssertLessThan(positions[3], positions[4], text)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: schema) as? NSDictionary)
        let reordered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        XCTAssertEqual(original, reordered)
    }

    func testAnAnswerReadsAsItsCategory() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Needs macOS 27") }
        let result = TriageResult(
            category: .notifyNow, confidence: 0.8, reason: "Kenji asks about Saturday",
            engine: .onDeviceModel, engineDetail: nil, interest: 4
        )
        XCTAssertEqual(SecondOpinionPrompt.parse(answer: OnDevicePath.answer(result))?.category, .notifyNow)
    }
}
