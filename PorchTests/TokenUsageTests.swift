@testable import Porch
import XCTest

final class TokenUsageTests: XCTestCase {

    func testTotalTokens() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 50)
        XCTAssertEqual(usage.totalTokens, 150)
    }

    func testFormattedTotalUnderThousand() {
        let usage = TokenUsage(promptTokens: 500, completionTokens: 200)
        XCTAssertEqual(usage.formattedTotal, "700")
    }

    func testFormattedTotalOverThousand() {
        let usage = TokenUsage(promptTokens: 1000, completionTokens: 500)
        XCTAssertEqual(usage.formattedTotal, "1.5K")
    }

    func testFormattedTotalExactlyThousand() {
        let usage = TokenUsage(promptTokens: 800, completionTokens: 200)
        XCTAssertEqual(usage.formattedTotal, "1.0K")
    }

    func testFormattedTotalZero() {
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0)
        XCTAssertEqual(usage.formattedTotal, "0")
    }

    func testFormatTokenCountSmall() {
        XCTAssertEqual(TokenUsage.formatTokenCount(42), "42")
    }

    func testFormatTokenCountLarge() {
        XCTAssertEqual(TokenUsage.formatTokenCount(12345), "12.3K")
    }

    func testEquality() {
        let a = TokenUsage(promptTokens: 10, completionTokens: 20)
        let b = TokenUsage(promptTokens: 10, completionTokens: 20)
        XCTAssertEqual(a, b)
    }
}
