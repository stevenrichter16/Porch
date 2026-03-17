import XCTest
@testable import Porch

final class PorchCoreTests: XCTestCase {
    func testNormalizeBaseURLAppendsV1WhenMissing() async throws {
        let client = OpenAICompatibleClient()
        let url = try await client.normalizeBaseURL("192.168.1.5:1234")
        XCTAssertEqual(url.absoluteString, "http://192.168.1.5:1234/v1")
    }

    func testNormalizeBaseURLPreservesExistingV1Path() async throws {
        let client = OpenAICompatibleClient()
        let url = try await client.normalizeBaseURL("https://example.com/api/v1")
        XCTAssertEqual(url.absoluteString, "https://example.com/api/v1")
    }

    func testSSEParserAcceptsPayloadWithoutSpace() throws {
        let parser = SSEParser()
        let line = #"data:{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#

        let result = try parser.parse(line: line)
        switch result {
        case .chunk(let chunk):
            XCTAssertEqual(chunk.choices.first?.delta.content, "Hi")
        default:
            XCTFail("Expected a chunk event.")
        }
    }

    func testSSEParserRecognizesDoneSentinel() throws {
        let parser = SSEParser()
        let result = try parser.parse(line: "data: [DONE]")

        switch result {
        case .done:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected the [DONE] sentinel.")
        }
    }

    func testChatTitleGeneratorTruncatesLongMessages() {
        let title = ChatTitleGenerator.title(for: "This is a very long first message that should be trimmed into a short, readable conversation title for the sidebar.")
        XCTAssertEqual(title, "This is a very long first message that should...")
    }

    func testAppSettingsRoundTripsGenerationParameters() {
        let settings = AppSettings()
        let parameters = GenerationParameters(
            temperature: 1.1,
            maxTokens: 4096,
            topP: 0.8,
            frequencyPenalty: 0.4,
            presencePenalty: -0.2,
            stopSequences: ["```", "</END>"]
        )

        settings.generationParameters = parameters

        XCTAssertEqual(settings.generationParameters, parameters)
    }
}
