@testable import Porch
import XCTest

final class ThinkingContentParserTests: XCTestCase {

    // MARK: - parse()

    func testParseWithNoThinkTags() {
        let result = ThinkingContentParser.parse("Hello, how can I help?")
        XCTAssertEqual(result.thinking, "")
        XCTAssertEqual(result.visible, "Hello, how can I help?")
    }

    func testParseWithThinkBlock() {
        let input = "<think>Let me consider this carefully.</think>The answer is 42."
        let result = ThinkingContentParser.parse(input)
        XCTAssertEqual(result.thinking, "Let me consider this carefully.")
        XCTAssertEqual(result.visible, "The answer is 42.")
    }

    func testParseWithThinkingBlock() {
        let input = "<thinking>Reasoning step 1\nReasoning step 2</thinking>Final answer."
        let result = ThinkingContentParser.parse(input)
        XCTAssertEqual(result.thinking, "Reasoning step 1\nReasoning step 2")
        XCTAssertEqual(result.visible, "Final answer.")
    }

    func testParseWithMultipleThinkBlocks() {
        let input = "<think>First thought.</think>Middle text.<think>Second thought.</think>Final."
        let result = ThinkingContentParser.parse(input)
        XCTAssertTrue(result.thinking.contains("First thought."))
        XCTAssertTrue(result.thinking.contains("Second thought."))
        XCTAssertEqual(result.visible, "Middle text.Final.")
    }

    func testParseWithEmptyThinkBlock() {
        let input = "<think></think>Just the answer."
        let result = ThinkingContentParser.parse(input)
        XCTAssertEqual(result.thinking, "")
        XCTAssertEqual(result.visible, "Just the answer.")
    }

    func testParseWithOnlyThinkBlock() {
        let input = "<think>All thinking, no answer.</think>"
        let result = ThinkingContentParser.parse(input)
        XCTAssertEqual(result.thinking, "All thinking, no answer.")
        XCTAssertEqual(result.visible, "")
    }

    func testParsePreservesWhitespace() {
        let input = "  <think>  thought  </think>  visible  "
        let result = ThinkingContentParser.parse(input)
        XCTAssertEqual(result.thinking, "thought")
        XCTAssertEqual(result.visible, "visible")
    }

    // MARK: - isInsideThinkBlock()

    func testIsInsideThinkBlockWhenOpen() {
        XCTAssertTrue(ThinkingContentParser.isInsideThinkBlock("<think>still going"))
    }

    func testIsInsideThinkBlockWhenClosed() {
        XCTAssertFalse(ThinkingContentParser.isInsideThinkBlock("<think>done</think>"))
    }

    func testIsInsideThinkBlockWithNoTags() {
        XCTAssertFalse(ThinkingContentParser.isInsideThinkBlock("plain text"))
    }

    func testIsInsideThinkBlockWithThinkingTag() {
        XCTAssertTrue(ThinkingContentParser.isInsideThinkBlock("<thinking>still going"))
    }

    func testIsInsideThinkBlockPartiallyClosedThenReopened() {
        XCTAssertTrue(ThinkingContentParser.isInsideThinkBlock("<think>a</think><think>b"))
    }

    func testIsInsideThinkBlockFullyClosed() {
        XCTAssertFalse(ThinkingContentParser.isInsideThinkBlock("<think>a</think><think>b</think>"))
    }
}
