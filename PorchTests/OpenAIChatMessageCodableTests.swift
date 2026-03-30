@testable import Porch
import XCTest

final class OpenAIChatMessageCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Plain text encoding

    func testEncodeTextMessage() throws {
        let msg = OpenAIChatMessage(role: "user", content: "Hello")
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["role"] as? String, "user")
        XCTAssertEqual(json["content"] as? String, "Hello")
    }

    // MARK: - Vision format encoding

    func testEncodeVisionMessage() throws {
        let msg = OpenAIChatMessage(role: "user", contentParts: [
            .text("What is in this image?"),
            .imageURL("data:image/jpeg;base64,abc123")
        ])
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["role"] as? String, "user")
        let contentArray = json["content"] as? [[String: Any]]
        XCTAssertNotNil(contentArray)
        XCTAssertEqual(contentArray?.count, 2)
        XCTAssertEqual(contentArray?[0]["type"] as? String, "text")
        XCTAssertEqual(contentArray?[0]["text"] as? String, "What is in this image?")
        XCTAssertEqual(contentArray?[1]["type"] as? String, "image_url")
    }

    // MARK: - Plain text decode

    func testDecodeTextMessage() throws {
        let json = """
        {"role": "assistant", "content": "Hello back!"}
        """
        let msg = try decoder.decode(OpenAIChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertEqual(msg.content, "Hello back!")
        XCTAssertNil(msg.contentParts)
    }

    // MARK: - Vision format decode (array content)

    func testDecodeArrayContentMessage() throws {
        let json = """
        {"role": "assistant", "content": [{"type": "text", "text": "I see a cat."}]}
        """
        let msg = try decoder.decode(OpenAIChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertNotNil(msg.contentParts)
        XCTAssertEqual(msg.contentParts?.count, 1)
        XCTAssertEqual(msg.contentParts?[0].text, "I see a cat.")
        XCTAssertEqual(msg.content, "I see a cat.")
    }

    // MARK: - Tool calls

    func testDecodeToolCallMessage() throws {
        let json = """
        {"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "web_search", "arguments": "{\\"query\\":\\"test\\"}"}}]}
        """
        let msg = try decoder.decode(OpenAIChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.tool_calls?.count, 1)
        XCTAssertEqual(msg.tool_calls?[0].function.name, "web_search")
    }

    // MARK: - Round-trip

    func testRoundTripPlainText() throws {
        let original = OpenAIChatMessage(role: "user", content: "Hello")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenAIChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }

    // MARK: - ContentPart

    func testContentPartText() {
        let part = ContentPart.text("Hello")
        XCTAssertEqual(part.type, "text")
        XCTAssertEqual(part.text, "Hello")
        XCTAssertNil(part.image_url)
    }

    func testContentPartImageURL() {
        let part = ContentPart.imageURL("data:image/png;base64,...")
        XCTAssertEqual(part.type, "image_url")
        XCTAssertNil(part.text)
        XCTAssertEqual(part.image_url?.url, "data:image/png;base64,...")
    }

    // MARK: - APIUsage

    func testAPIUsageConversion() {
        let usage = APIUsage(prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
        let tokenUsage = usage.asTokenUsage
        XCTAssertNotNil(tokenUsage)
        XCTAssertEqual(tokenUsage?.promptTokens, 100)
        XCTAssertEqual(tokenUsage?.completionTokens, 50)
    }

    func testAPIUsageNilWhenPartial() {
        let usage = APIUsage(prompt_tokens: nil, completion_tokens: 50, total_tokens: nil)
        XCTAssertNil(usage.asTokenUsage)
    }
}
