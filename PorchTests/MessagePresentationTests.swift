import Foundation
import XCTest
@testable import Porch

final class MessagePresentationTests: XCTestCase {
    func testTimestampFormatterUsesTimeForSameDayMessages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let formatterOutput = MessageTimestampFormatter.string(
            for: Date(timeIntervalSince1970: 3_600),
            relativeTo: Date(timeIntervalSince1970: 7_200),
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(normalizedTimestamp(formatterOutput), "1:00 AM")
    }

    func testTimestampFormatterUsesShortDateAndTimeForOlderMessages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let formatterOutput = MessageTimestampFormatter.string(
            for: Date(timeIntervalSince1970: 0),
            relativeTo: Date(timeIntervalSince1970: 172_800),
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        let normalizedOutput = normalizedTimestamp(formatterOutput)
        XCTAssertTrue(normalizedOutput.contains("Jan 1"))
        XCTAssertTrue(normalizedOutput.contains("12:00 AM"))
    }

    func testDiscardConfirmationRequiredOnlyWhenLaterMessagesExist() {
        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        let first = ChatMessage(role: .user, content: "First", thread: thread, createdAt: Date(timeIntervalSince1970: 10))
        let second = ChatMessage(role: .assistant, content: "Second", thread: thread, createdAt: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(ChatEditResendPolicy.requiresDiscardConfirmation(for: first.id, in: [first, second]))
        XCTAssertFalse(ChatEditResendPolicy.requiresDiscardConfirmation(for: second.id, in: [first, second]))
    }

    func testCodeBlockLanguageLabelFallsBackToCode() {
        XCTAssertEqual(MarkdownCodeBlockPresentation.languageLabel(for: nil), "Code")
        XCTAssertEqual(MarkdownCodeBlockPresentation.languageLabel(for: "swift"), "swift")
        XCTAssertEqual(MarkdownCodeBlockPresentation.languageLabel(for: "swift linenums"), "swift")
    }

    private func normalizedTimestamp(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: " at ", with: " ")
    }
}
