import Combine
import SwiftData
import XCTest
@testable import Porch

@MainActor
final class ChatViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testSendPersistsUserAndAssistantMessages() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Hello from Porch", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Hello from iPhone"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        XCTAssertEqual(harness.chat.title, "Hello from iPhone")
        XCTAssertEqual(harness.chat.sortedMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(harness.chat.sortedMessages[0].content, "Hello from iPhone")
        XCTAssertEqual(harness.chat.sortedMessages[1].content, "Hello from Porch")
        XCTAssertFalse(harness.chat.sortedMessages[1].isPartial)
        XCTAssertEqual(harness.chat.lastMessagePreview, "Hello from Porch")
    }

    func testRegenerateReplacesLastAssistantMessageWithoutDuplicates() async throws {
        let harness = try makeHarness()
        var callCount = 0

        MockURLProtocol.setRequestHandler { _ in
            defer { callCount += 1 }
            let reply = callCount == 0 ? "First answer" : "Second answer"
            let delay = callCount == 0 ? UInt64.zero : 150_000_000
            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: reply, finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ], delayNanoseconds: delay)
        }

        harness.viewModel.composerText = "Regenerate me"
        harness.viewModel.sendCurrentInput()
        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }
        XCTAssertEqual(harness.chat.lastMessagePreview, "First answer")

        harness.viewModel.regenerateLastResponse()
        XCTAssertEqual(harness.chat.lastMessagePreview, "Regenerate me")
        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistants = harness.chat.sortedMessages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.content, "Second answer")
        XCTAssertEqual(harness.chat.sortedMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(harness.chat.lastMessagePreview, "Second answer")
    }

    func testStopGeneratingPersistsPartialAssistantMessage() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setRequestHandler { _ in
            .stream(
                bodyChunks: [
                    try self.makeSSEChunk(content: "Hel", finishReason: nil),
                    try self.makeSSEChunk(content: "lo", finishReason: nil),
                    Data("data: [DONE]\n".utf8)
                ],
                delayNanoseconds: 150_000_000
            )
        }

        harness.viewModel.composerText = "Please stop"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            harness.viewModel.streamingText == "Hel"
        }

        harness.viewModel.stopGenerating()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistant = try XCTUnwrap(harness.chat.sortedMessages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.content, "Hel")
        XCTAssertTrue(assistant.isPartial)
        XCTAssertEqual(assistant.finishReason, .cancelled)
        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.chat.lastMessagePreview, "Hel")
    }

    func testPostTokenNetworkFailurePersistsSinglePartialAssistantAndError() async throws {
        let harness = try makeHarness()
        let expectedError = NSError(
            domain: "PorchTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Socket closed"]
        )

        MockURLProtocol.setRequestHandler { _ in
            .stream(
                bodyChunks: [
                    try self.makeSSEChunk(content: "Par", finishReason: nil)
                ],
                delayNanoseconds: 50_000_000,
                completionError: expectedError
            )
        }

        harness.viewModel.composerText = "Trigger failure"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistants = harness.chat.sortedMessages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.content, "Par")
        XCTAssertTrue(assistants.first?.isPartial == true)
        XCTAssertEqual(harness.viewModel.errorMessage, "Socket closed")
        XCTAssertEqual(harness.chat.lastMessagePreview, "Par")
    }

    func testLengthFinishReasonPersistsInfoMessage() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Long reply", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "length"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Give me everything"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistant = try XCTUnwrap(harness.chat.sortedMessages.last)
        XCTAssertEqual(assistant.finishReason, .length)
        XCTAssertEqual(
            harness.viewModel.infoMessage,
            "Response stopped because the max token limit was reached."
        )
    }

    func testBufferedCompletionPublishesFewerUpdatesThanTokenCountAndPersistsFullReply() async throws {
        let harness = try makeHarness()
        let tokens = ["Hel", "lo", " ", "from", " ", "buffered"]
        let fullReply = tokens.joined()
        var publishedDrafts: [String] = []
        let cancellable = harness.viewModel.$streamingText
            .sink { text in
                guard !text.isEmpty else { return }
                publishedDrafts.append(text)
            }
        defer { cancellable.cancel() }

        MockURLProtocol.setRequestHandler { _ in
            .stream(
                bodyChunks: try tokens.map { try self.makeSSEChunk(content: $0, finishReason: nil) } + [
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ],
                delayNanoseconds: 5_000_000
            )
        }

        harness.viewModel.composerText = "Buffer this"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistant = try XCTUnwrap(harness.chat.sortedMessages.last)
        XCTAssertEqual(assistant.content, fullReply)
        XCTAssertLessThan(publishedDrafts.count, tokens.count)
        XCTAssertEqual(publishedDrafts.last, fullReply)
        XCTAssertEqual(harness.chat.lastMessagePreview, fullReply)
    }

    func testBufferedCancellationPersistsDraftBeforeLivePublish() async throws {
        let harness = try makeHarness()
        let firstChunkDelivered = expectation(description: "First chunk delivered")
        MockURLProtocol.setRequestHandler { _ in
            .stream(
                bodyChunks: [
                    try self.makeSSEChunk(content: "Hel", finishReason: nil),
                    try self.makeSSEChunk(content: "lo", finishReason: nil),
                    Data("data: [DONE]\n".utf8)
                ],
                delayNanoseconds: 40_000_000
            )
        }
        MockURLProtocol.setChunkObserver { chunkCount in
            guard chunkCount == 1 else { return }
            firstChunkDelivered.fulfill()
        }

        harness.viewModel.composerText = "Cancel before publish"
        harness.viewModel.sendCurrentInput()

        await fulfillment(of: [firstChunkDelivered], timeout: 1)
        XCTAssertEqual(harness.viewModel.streamingText, "")

        harness.viewModel.stopGenerating()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistant = try XCTUnwrap(harness.chat.sortedMessages.last)
        XCTAssertEqual(assistant.content, "Hel")
        XCTAssertTrue(assistant.isPartial)
        XCTAssertEqual(assistant.finishReason, .cancelled)
        XCTAssertEqual(harness.chat.lastMessagePreview, "Hel")
    }

    func testBufferedFailurePersistsEntireUnpublishedDraft() async throws {
        let harness = try makeHarness()
        let expectedError = NSError(
            domain: "PorchTests",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Socket closed"]
        )
        var publishedDrafts: [String] = []
        let cancellable = harness.viewModel.$streamingText
            .sink { text in
                guard !text.isEmpty else { return }
                publishedDrafts.append(text)
            }
        defer { cancellable.cancel() }

        MockURLProtocol.setRequestHandler { _ in
            .stream(
                bodyChunks: [
                    try self.makeSSEChunk(content: "Buf", finishReason: nil),
                    try self.makeSSEChunk(content: "fer", finishReason: nil),
                    try self.makeSSEChunk(content: "ed", finishReason: nil)
                ],
                delayNanoseconds: 5_000_000,
                completionError: expectedError
            )
        }

        harness.viewModel.composerText = "Break after buffering"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let assistant = try XCTUnwrap(harness.chat.sortedMessages.last)
        XCTAssertEqual(assistant.content, "Buffered")
        XCTAssertTrue(assistant.isPartial)
        XCTAssertEqual(harness.viewModel.errorMessage, "Socket closed")
        XCTAssertEqual(publishedDrafts, ["Buffered"])
        XCTAssertEqual(harness.chat.lastMessagePreview, "Buffered")
    }

    private func makeHarness() throws -> Harness {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)

        let settings = AppSettings()
        settings.activeBaseURL = "http://server.test:8080"
        settings.defaultModelID = "llama-3"
        settings.defaultSystemPrompt = "You are helpful."
        settings.availableModels = [RemoteModel(id: "llama-3", ownedBy: "local")]
        settings.validationState = .valid
        context.insert(settings)

        let chat = ChatThread(
            serverBaseURL: settings.activeBaseURL,
            modelID: settings.defaultModelID,
            systemPrompt: settings.defaultSystemPrompt
        )
        context.insert(chat)
        try context.save()

        let keychain = MemoryKeychainStore()
        try keychain.save("secret", account: "active-server-api-key")

        let client = OpenAICompatibleClient(session: TestSessionFactory.makeSession())
        let viewModel = ChatViewModel(
            chat: chat,
            settings: settings,
            modelContext: context,
            client: client,
            keychain: keychain
        )

        return Harness(
            container: container,
            context: context,
            settings: settings,
            chat: chat,
            keychain: keychain,
            viewModel: viewModel
        )
    }

    private func makeSSEChunk(content: String?, finishReason: String?) throws -> Data {
        var delta: [String: Any] = [:]
        if let content {
            delta["content"] = content
        }
        let finishReasonValue: Any = finishReason.map { $0 as Any } ?? NSNull()

        let payload = try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    [
                        "index": 0,
                        "delta": delta,
                        "finish_reason": finishReasonValue
                    ]
                ]
            ]
        )

        var line = Data("data: ".utf8)
        line.append(payload)
        line.append(Data("\n".utf8))
        return line
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition.", file: file, line: line)
    }

    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let settings: AppSettings
        let chat: ChatThread
        let keychain: MemoryKeychainStore
        let viewModel: ChatViewModel
    }
}
