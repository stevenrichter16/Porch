import XCTest
@testable import Porch

final class TextToolCallParserTests: XCTestCase {

    // MARK: - XML-style <tool_call> blocks

    func testParsesXMLStyleToolCall() {
        let text = """
        I'll read the file for you.

        <tool_call>
        {"name": "github_get_file_content", "arguments": {"path": "README.md"}}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "github_get_file_content")
        XCTAssertTrue(result.toolCalls[0].arguments.contains("README.md"))
        XCTAssertTrue(result.remainingText.contains("I'll read the file"))
        XCTAssertFalse(result.remainingText.contains("<tool_call>"))
    }

    func testParsesMultipleXMLToolCalls() {
        let text = """
        Let me look at both files.

        <tool_call>
        {"name": "github_get_file_content", "arguments": {"path": "README.md"}}
        </tool_call>

        <tool_call>
        {"name": "github_get_file_content", "arguments": {"path": "Package.swift"}}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "github_get_file_content")
        XCTAssertEqual(result.toolCalls[1].name, "github_get_file_content")
    }

    // MARK: - Fenced code block style

    func testParsesFencedToolCall() {
        let text = """
        I'll search for that.

        ```tool_call
        {"name": "web_search", "arguments": {"query": "Swift concurrency"}}
        ```
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "web_search")
        XCTAssertTrue(result.toolCalls[0].arguments.contains("Swift concurrency"))
    }

    // MARK: - Arguments formats

    func testHandlesArgumentsAsObject() {
        let text = """
        <tool_call>
        {"name": "github_get_repo_tree", "arguments": {"path_prefix": "Sources", "max_entries": 100}}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "github_get_repo_tree")
        // Arguments should be a JSON string
        let argData = result.toolCalls[0].arguments.data(using: .utf8)!
        let argDict = try? JSONDecoder().decode([String: String].self, from: argData)
        // It might have mixed types so just verify it's valid JSON
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: argData))
    }

    func testHandlesArgumentsAsString() {
        let text = """
        <tool_call>
        {"name": "web_search", "arguments": "{\\"query\\": \\"hello\\"}"}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "web_search")
    }

    // MARK: - No tool calls

    func testReturnsEmptyForPlainText() {
        let text = "Hello! I'm happy to help you with your project."

        let result = TextToolCallParser.parse(text)

        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(result.remainingText, text)
    }

    func testReturnsEmptyForMalformedJSON() {
        let text = """
        <tool_call>
        this is not json
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertTrue(result.toolCalls.isEmpty)
    }

    func testIgnoresEmptyToolName() {
        let text = """
        <tool_call>
        {"name": "", "arguments": {"path": "test"}}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertTrue(result.toolCalls.isEmpty)
    }

    // MARK: - Deduplication

    func testDeduplicatesMatchingBothPatterns() {
        // If the same tool call somehow matches both patterns, it should be deduplicated
        let text = """
        <tool_call>
        {"name": "web_search", "arguments": {"query": "test"}}
        </tool_call>

        <tool_call>
        {"name": "web_search", "arguments": {"query": "test"}}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        // Both have the same name+arguments, should be deduplicated
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    // MARK: - Remaining text

    func testRemainingTextStripsToolCallBlocks() {
        let text = """
        Before the call.

        <tool_call>
        {"name": "web_search", "arguments": {"query": "test"}}
        </tool_call>

        After the call.
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.remainingText.contains("Before the call"))
        XCTAssertTrue(result.remainingText.contains("After the call"))
        XCTAssertFalse(result.remainingText.contains("tool_call"))
    }

    func testNoArgumentsDefaultsToEmptyObject() {
        let text = """
        <tool_call>
        {"name": "github_get_repo_tree"}
        </tool_call>
        """

        let result = TextToolCallParser.parse(text)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].arguments, "{}")
    }
}
