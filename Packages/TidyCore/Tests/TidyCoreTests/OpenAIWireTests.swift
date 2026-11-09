import XCTest
@testable import TidyCore

final class OpenAIWireTests: XCTestCase {
    func testBody() throws {
        let data = try OpenAIWire.body(model: "gpt-5", system: "sys", content: [.text("hi"), .jpeg(Data([1, 2, 3]))],
                                       schema: Prompts.schemaObject(Prompts.askSchema), schemaName: "tidy_answer", effort: .low)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["model"] as? String, "gpt-5")
        XCTAssertEqual(o["instructions"] as? String, "sys")
        XCTAssertEqual((o["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let format = try XCTUnwrap((o["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let input = try XCTUnwrap((o["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(input[0]["type"] as? String, "input_text")
        XCTAssertEqual(input[1]["image_url"] as? String, "data:image/jpeg;base64,AQID")
    }

    func testReasoningOnlyForReasoningModels() {
        XCTAssertTrue(OpenAIWire.supportsReasoning("gpt-5"))
        XCTAssertTrue(OpenAIWire.supportsReasoning("gpt-6.1-terra"))
        XCTAssertTrue(OpenAIWire.supportsReasoning("o3"))
        XCTAssertFalse(OpenAIWire.supportsReasoning("gpt-4.1"))
    }

    func testParsing() throws {
        let ok = #"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"answer\":\"Desk drawer\",\"item_refs\":[\"i4\"]}"}]}]}"#
        XCTAssertEqual(try OpenAIWire.decode(AskResult.self, status: 200, data: Data(ok.utf8)).itemRefs, ["i4"])
        let refusal = #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#
        XCTAssertThrowsError(try OpenAIWire.decode(AskResult.self, status: 200, data: Data(refusal.utf8))) {
            XCTAssertEqual($0 as? ClaudeWire.Failure, .refused)
        }
        let cut = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        XCTAssertThrowsError(try OpenAIWire.decode(AskResult.self, status: 200, data: Data(cut.utf8))) {
            XCTAssertEqual($0 as? ClaudeWire.Failure, .tooLong)
        }
        XCTAssertThrowsError(try OpenAIWire.decode(AskResult.self, status: 401, data: Data("{}".utf8))) {
            XCTAssertEqual($0 as? ClaudeWire.Failure, .badKey)
        }
    }

    func testPickModel() {
        let list = #"""
        {"data":[{"id":"gpt-4.1","created":100},{"id":"gpt-5","created":200},{"id":"gpt-5-mini","created":300},
                 {"id":"gpt-5-2025-08-07","created":250},{"id":"whisper-1","created":400},{"id":"gpt-6-astra","created":350},
                 {"id":"gpt-6-astra-realtime","created":360}]}
        """#
        XCTAssertEqual(OpenAIWire.pickModel(fromModelsList: Data(list.utf8)), "gpt-6-astra")
        XCTAssertNil(OpenAIWire.pickModel(fromModelsList: Data("{}".utf8)))
    }

    func testOrder() {
        XCTAssertEqual(AIPreference.claudeFirst.order(hasClaude: true, hasChatGPT: true), [.claude, .chatgpt])
        XCTAssertEqual(AIPreference.claudeFirst.order(hasClaude: false, hasChatGPT: true), [.chatgpt])
        XCTAssertEqual(AIPreference.chatgptOnly.order(hasClaude: true, hasChatGPT: false), [])
        XCTAssertTrue(ClaudeWire.worthTryingAnother(ClaudeWire.Failure.overloaded))
        XCTAssertFalse(ClaudeWire.worthTryingAnother(ClaudeWire.Failure.noKey))
    }
}

final class OpenAIImageWireTests: XCTestCase {
    func testMultipartAndParse() throws {
        let r = OpenAIImageWire.request(model: "gpt-image-1", prompt: "Calm room", jpeg: Data([0xFF, 0xD8]), boundary: "B")
        XCTAssertEqual(r.contentType, "multipart/form-data; boundary=B")
        let text = String(decoding: r.body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nCalm room\r\n"))
        XCTAssertTrue(text.contains("filename=\"room.jpg\""))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
        let ok = #"{"data":[{"b64_json":"AQID"}]}"#
        XCTAssertEqual(try OpenAIImageWire.image(status: 200, data: Data(ok.utf8)), Data([1, 2, 3]))
        XCTAssertThrowsError(try OpenAIImageWire.image(status: 401, data: Data("{}".utf8)))
    }
}
