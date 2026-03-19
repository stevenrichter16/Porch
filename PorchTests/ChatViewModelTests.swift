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
                delayNanoseconds: 200_000_000
            )
        }
        MockURLProtocol.setChunkObserver { chunkCount in
            guard chunkCount == 1 else { return }
            firstChunkDelivered.fulfill()
        }

        harness.viewModel.composerText = "Cancel before publish"
        harness.viewModel.sendCurrentInput()

        await fulfillment(of: [firstChunkDelivered], timeout: 1)
        try? await Task.sleep(nanoseconds: 10_000_000)

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
        XCTAssertEqual(harness.chat.lastMessagePreview, "Buffered")
    }

    func testEditingLastUserMessageResendsFromUpdatedContentWithoutCreatingDuplicateUserMessage() async throws {
        let harness = try makeHarness()
        var callCount = 0

        MockURLProtocol.setRequestHandler { _ in
            defer { callCount += 1 }
            let reply = callCount == 0 ? "First answer" : "Updated answer"
            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: reply, finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Original prompt"
        harness.viewModel.sendCurrentInput()
        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let originalUserMessage = try XCTUnwrap(harness.chat.sortedMessages.first)

        harness.viewModel.editUserMessageAndResend(
            messageID: originalUserMessage.id,
            newText: "Updated prompt"
        )

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let refreshedMessages = harness.chat.sortedMessages
        XCTAssertEqual(refreshedMessages.first?.id, originalUserMessage.id)
        XCTAssertEqual(refreshedMessages.first?.content, "Updated prompt")
        XCTAssertEqual(refreshedMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(refreshedMessages.last?.content, "Updated answer")
        XCTAssertEqual(harness.chat.lastMessagePreview, "Updated answer")
    }

    func testEditingMiddleUserMessageDeletesLaterMessagesBeforeRegeneration() async throws {
        let harness = try makeHarness()
        let userOne = ChatMessage(
            role: .user,
            content: "First question",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let assistantOne = ChatMessage(
            role: .assistant,
            content: "First answer",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let userTwo = ChatMessage(
            role: .user,
            content: "Second question",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let assistantTwo = ChatMessage(
            role: .assistant,
            content: "Second answer",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 40)
        )
        harness.context.insert(userOne)
        harness.context.insert(assistantOne)
        harness.context.insert(userTwo)
        harness.context.insert(assistantTwo)
        harness.chat.applyMessageMutation(latestMessage: assistantTwo)
        try harness.context.save()

        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Replacement answer", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.editUserMessageAndResend(
            messageID: userOne.id,
            newText: "Edited first question"
        )

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let refreshedMessages = harness.chat.sortedMessages
        XCTAssertEqual(refreshedMessages.map(\.content), ["Edited first question", "Replacement answer"])
        XCTAssertEqual(refreshedMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(refreshedMessages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(harness.chat.lastMessagePreview, "Replacement answer")
    }

    func testNextMessageOverrideIsConsumedByFreshSendOnlyOnce() async throws {
        let harness = try makeHarness()
        let override = GenerationParameters(
            temperature: 1.35,
            maxTokens: 4096,
            topP: 0.55,
            frequencyPenalty: 0.4,
            presencePenalty: 0.6,
            stopSequences: ["DONE"]
        )

        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Override reply", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.nextMessageParameterOverride = override
        harness.viewModel.composerText = "Use the override"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        XCTAssertNil(harness.viewModel.nextMessageParameterOverride)

        harness.viewModel.composerText = "Use defaults now"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 4
        }

        let requests = MockURLProtocol.capturedRequests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(requests.count, 2)

        let firstBody = try requestBodyJSON(for: requests[0])
        XCTAssertEqual(firstBody["temperature"] as? Double, override.temperature)
        XCTAssertEqual(firstBody["max_tokens"] as? Int, override.maxTokens)
        XCTAssertEqual(firstBody["top_p"] as? Double, override.topP)
        XCTAssertEqual(firstBody["frequency_penalty"] as? Double, override.frequencyPenalty)
        XCTAssertEqual(firstBody["presence_penalty"] as? Double, override.presencePenalty)
        XCTAssertEqual(firstBody["stop"] as? [String], override.stopSequences)

        let secondBody = try requestBodyJSON(for: requests[1])
        XCTAssertEqual(secondBody["temperature"] as? Double, harness.settings.generationParameters.temperature)
        XCTAssertEqual(secondBody["max_tokens"] as? Int, harness.settings.generationParameters.maxTokens)
        XCTAssertEqual(secondBody["top_p"] as? Double, harness.settings.generationParameters.topP)
        XCTAssertEqual(secondBody["frequency_penalty"] as? Double, harness.settings.generationParameters.frequencyPenalty)
        XCTAssertEqual(secondBody["presence_penalty"] as? Double, harness.settings.generationParameters.presencePenalty)
        XCTAssertNil(secondBody["stop"])
    }

    func testRegenerateUsesDefaultsAndDoesNotConsumePendingOverride() async throws {
        let harness = try makeHarness()
        let override = GenerationParameters(
            temperature: 1.6,
            maxTokens: 8192,
            topP: 0.45,
            frequencyPenalty: 0.3,
            presencePenalty: 0.5,
            stopSequences: ["STOP"]
        )
        let user = ChatMessage(
            role: .user,
            content: "Question",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Old answer",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        harness.context.insert(user)
        harness.context.insert(assistant)
        harness.chat.applyMessageMutation(latestMessage: assistant)
        try harness.context.save()

        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Replacement", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.nextMessageParameterOverride = override
        harness.viewModel.regenerateLastResponse()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        XCTAssertEqual(harness.viewModel.nextMessageParameterOverride, override)

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.httpMethod == "POST" }))
        let body = try requestBodyJSON(for: request)
        XCTAssertEqual(body["temperature"] as? Double, harness.settings.generationParameters.temperature)
        XCTAssertEqual(body["max_tokens"] as? Int, harness.settings.generationParameters.maxTokens)
        XCTAssertEqual(body["top_p"] as? Double, harness.settings.generationParameters.topP)
        XCTAssertEqual(body["frequency_penalty"] as? Double, harness.settings.generationParameters.frequencyPenalty)
        XCTAssertEqual(body["presence_penalty"] as? Double, harness.settings.generationParameters.presencePenalty)
        XCTAssertNil(body["stop"])
    }

    func testEditResendUsesDefaultsAndDoesNotConsumePendingOverride() async throws {
        let harness = try makeHarness()
        let override = GenerationParameters(
            temperature: 1.7,
            maxTokens: 6144,
            topP: 0.35,
            frequencyPenalty: 0.2,
            presencePenalty: 0.7,
            stopSequences: ["END"]
        )
        let user = ChatMessage(
            role: .user,
            content: "Original question",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Original answer",
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        harness.context.insert(user)
        harness.context.insert(assistant)
        harness.chat.applyMessageMutation(latestMessage: assistant)
        try harness.context.save()

        MockURLProtocol.setRequestHandler { _ in
            .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Edited answer", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.nextMessageParameterOverride = override
        harness.viewModel.editUserMessageAndResend(
            messageID: user.id,
            newText: "Edited question"
        )

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        XCTAssertEqual(harness.viewModel.nextMessageParameterOverride, override)

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.httpMethod == "POST" }))
        let body = try requestBodyJSON(for: request)
        XCTAssertEqual(body["temperature"] as? Double, harness.settings.generationParameters.temperature)
        XCTAssertEqual(body["max_tokens"] as? Int, harness.settings.generationParameters.maxTokens)
        XCTAssertEqual(body["top_p"] as? Double, harness.settings.generationParameters.topP)
        XCTAssertEqual(body["frequency_penalty"] as? Double, harness.settings.generationParameters.frequencyPenalty)
        XCTAssertEqual(body["presence_penalty"] as? Double, harness.settings.generationParameters.presencePenalty)
        XCTAssertNil(body["stop"])
    }

    func testGitHubToolsAreNotExposedWithoutChatContext() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: { $0.isGitHubConnectorEnabled = true },
            keychain: keychain
        )

        MockURLProtocol.setRequestHandler { request in
            guard request.url?.host == "server.test" else {
                XCTFail("Unexpected request host: \(request.url?.host ?? "nil")")
                return .data(statusCode: 500)
            }

            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: "No GitHub tools were available.", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Inspect the repo"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.url?.host == "server.test" }))
        let body = try requestBodyJSON(for: request)
        XCTAssertNil(body["tools"])
    }

    func testWebSearchToolsAreExposedWhenEnabledAndExecuteSearchTool() async throws {
        let harness = try makeHarness(
            configureSettings: { $0.isWebSearchConnectorEnabled = true },
            webSearchConnector: WebSearchConnector(session: TestSessionFactory.makeSession())
        )
        let requestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                if requestCounter.next() == 0 {
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "web_search",
                        arguments: #"{"query":"porch coding app","max_results":1}"#
                    ))
                }
                return .stream(bodyChunks: [
                    try self.makeSSEChunk(content: "I found a useful result.", finishReason: nil),
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ])

            case ("html.duckduckgo.com", "GET", let path) where path.hasPrefix("/html"):
                return .data(body: Data("""
                <html><body>
                <div class="result__body">
                  <h2><a class="result__a" href="https://example.com/porch">Porch Search Result</a></h2>
                  <a class="result__snippet">A concise snippet about Porch.</a>
                </div>
                </body></html>
                """.utf8))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Search the web"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 4
        }

        let serverRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "server.test" && $0.httpMethod == "POST"
        }
        XCTAssertEqual(serverRequests.count, 2)

        let firstBody = try requestBodyJSON(for: serverRequests[0])
        let tools = try XCTUnwrap(firstBody["tools"] as? [[String: Any]])
        let toolNames = tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(toolNames.contains("web_search"))
        XCTAssertTrue(toolNames.contains("web_fetch_page"))

        let toolMessage = try XCTUnwrap(harness.chat.sortedMessages.first(where: { $0.role == .tool }))
        let toolPayload = try makeJSONObject(from: toolMessage.content)
        let results = try XCTUnwrap(toolPayload["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["title"] as? String, "Porch Search Result")
        XCTAssertEqual(results.first?["url"] as? String, "https://example.com/porch")
        XCTAssertEqual(harness.chat.sortedMessages.last?.content, "I found a useful result.")
    }

    func testGitHubWriteToolWaitsForApprovalAndStopCancelsWithoutWriting() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: { $0.isGitHubConnectorEnabled = true },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                    toolName: "github_create_branch_and_commit_changes",
                    arguments: self.makeGitHubWriteArguments()
                ))

            case ("api.github.com", "GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "main",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("api.github.com", "GET", let path) where path.hasPrefix("/repos/octo/demo/git/ref/heads/porch/"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": []
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Create the file"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            harness.viewModel.pendingGitHubWriteApproval != nil
        }

        let approval = try XCTUnwrap(harness.viewModel.pendingGitHubWriteApproval)
        XCTAssertEqual(approval.repositoryFullName, "octo/demo")
        XCTAssertEqual(approval.resolvedBaseRef, "main")
        XCTAssertEqual(approval.changes.count, 1)
        XCTAssertEqual(approval.changes.first?.path, "Sources/NewFile.swift")
        XCTAssertEqual(harness.viewModel.streamingText, "Awaiting approval for GitHub changes...")

        let githubWriteRequestsBeforeStop = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.httpMethod == "POST"
        }
        XCTAssertTrue(githubWriteRequestsBeforeStop.isEmpty)

        harness.viewModel.stopGenerating()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.viewModel.pendingGitHubWriteApproval == nil
        }

        XCTAssertEqual(harness.chat.sortedMessages.map(\.role), [.user, .assistant])
        XCTAssertTrue(harness.chat.sortedMessages.filter { $0.role == .tool }.isEmpty)
    }

    func testGitHubWriteApprovalCancelPersistsCancelledToolResultAndContinuesConversation() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: { $0.isGitHubConnectorEnabled = true },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let localRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                if localRequestCounter.next() == 0 {
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_create_branch_and_commit_changes",
                        arguments: self.makeGitHubWriteArguments()
                    ))
                }
                return .stream(bodyChunks: [
                    try self.makeSSEChunk(content: "Understood. I did not push the GitHub changes.", finishReason: nil),
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ])

            case ("api.github.com", "GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "main",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("api.github.com", "GET", let path) where path.hasPrefix("/repos/octo/demo/git/ref/heads/porch/"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": []
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Prepare the branch"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            harness.viewModel.pendingGitHubWriteApproval != nil
        }

        harness.viewModel.cancelPendingGitHubWriteApproval()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 4
        }

        let roles = harness.chat.sortedMessages.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .tool, .assistant])
        XCTAssertTrue(harness.chat.sortedMessages[2].content.contains("\"status\":\"cancelled\""))
        XCTAssertTrue(harness.chat.sortedMessages[3].content.contains("did not push"))
        XCTAssertTrue(
            MockURLProtocol.capturedRequests.filter {
                $0.url?.host == "api.github.com" && $0.httpMethod == "POST"
            }.isEmpty
        )
    }

    func testGitHubWriteApprovalApproveExecutesWriteAndContinuesConversation() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: { $0.isGitHubConnectorEnabled = true },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let localRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                if localRequestCounter.next() == 0 {
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_create_branch_and_commit_changes",
                        arguments: self.makeGitHubWriteArguments()
                    ))
                }
                return .stream(bodyChunks: [
                    try self.makeSSEChunk(content: "The branch is ready on GitHub.", finishReason: nil),
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ])

            case ("api.github.com", "GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "main",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("api.github.com", "GET", let path) where
                path.hasPrefix("/repos/octo/demo/git/ref/heads/porch/") ||
                path == "/repos/octo/demo/git/ref/heads/codex/approved-branch":
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": []
                ]))

            case ("api.github.com", "POST", "/repos/octo/demo/git/blobs"):
                return .data(body: try self.makeJSONData([
                    "sha": "blob-1"
                ]))

            case ("api.github.com", "POST", "/repos/octo/demo/git/trees"):
                return .data(body: try self.makeJSONData([
                    "sha": "tree-2"
                ]))

            case ("api.github.com", "POST", "/repos/octo/demo/git/commits"):
                return .data(body: try self.makeJSONData([
                    "sha": "commit-2",
                    "html_url": "https://github.com/octo/demo/commit/commit-2"
                ]))

            case ("api.github.com", "POST", "/repos/octo/demo/git/refs"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/codex/approved-branch",
                    "object": [
                        "sha": "commit-2",
                        "type": "commit"
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Prepare the approved branch"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            harness.viewModel.pendingGitHubWriteApproval != nil
        }

        harness.viewModel.approvePendingGitHubWrite(
            branchName: "codex/approved-branch",
            commitMessage: "Apply the approved GitHub change"
        )

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 4
        }

        let toolMessage = try XCTUnwrap(harness.chat.sortedMessages.first(where: { $0.role == .tool }))
        XCTAssertTrue(toolMessage.content.contains("\"status\":\"success\""))
        XCTAssertTrue(toolMessage.content.contains("\"branch_name\":\"codex\\/approved-branch\""))
        XCTAssertEqual(harness.chat.sortedMessages.last?.content, "The branch is ready on GitHub.")

        let commitRequest = try XCTUnwrap(
            MockURLProtocol.capturedRequests.first(where: { $0.url?.path == "/repos/octo/demo/git/commits" })
        )
        let commitBody = try requestBodyJSON(for: commitRequest)
        XCTAssertEqual(commitBody["message"] as? String, "Apply the approved GitHub change")

        let refRequest = try XCTUnwrap(
            MockURLProtocol.capturedRequests.first(where: { $0.url?.path == "/repos/octo/demo/git/refs" })
        )
        let refBody = try requestBodyJSON(for: refRequest)
        XCTAssertEqual(refBody["ref"] as? String, "refs/heads/codex/approved-branch")
    }

    private func makeHarness(
        configureSettings: ((AppSettings) -> Void)? = nil,
        configureChat: ((ChatThread) -> Void)? = nil,
        keychain: MemoryKeychainStore? = nil,
        githubConnector: GitHubConnector? = nil,
        webSearchConnector: WebSearchConnector? = nil
    ) throws -> Harness {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)

        let settings = AppSettings()
        settings.activeBaseURL = "http://server.test:8080"
        settings.defaultModelID = "llama-3"
        settings.defaultSystemPrompt = "You are helpful."
        settings.availableModels = [RemoteModel(id: "llama-3", ownedBy: "local")]
        settings.validationState = .valid
        configureSettings?(settings)
        context.insert(settings)

        let chat = ChatThread(
            serverBaseURL: settings.activeBaseURL,
            modelID: settings.defaultModelID,
            systemPrompt: settings.defaultSystemPrompt
        )
        configureChat?(chat)
        context.insert(chat)
        try context.save()

        let keychain = keychain ?? MemoryKeychainStore()
        try keychain.save("secret", account: "active-server-api-key")

        let client = OpenAICompatibleClient(session: TestSessionFactory.makeSession())
        let viewModel = ChatViewModel(
            chat: chat,
            settings: settings,
            modelContext: context,
            client: client,
            keychain: keychain,
            githubConnector: githubConnector ?? GitHubConnector(keychain: keychain, session: TestSessionFactory.makeSession()),
            webSearchConnector: webSearchConnector ?? WebSearchConnector(session: TestSessionFactory.makeSession())
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

    private func makeToolCallSSEChunks(toolName: String, arguments: String) throws -> [Data] {
        let toolCallPayload = try makeJSONData([
            "choices": [
                [
                    "index": 0,
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0,
                                "id": "call_1",
                                "type": "function",
                                "function": [
                                    "name": toolName,
                                    "arguments": arguments
                                ]
                            ]
                        ]
                    ],
                    "finish_reason": NSNull()
                ]
            ]
        ])
        let finishPayload = try makeJSONData([
            "choices": [
                [
                    "index": 0,
                    "delta": [:],
                    "finish_reason": "tool_calls"
                ]
            ]
        ])
        return [
            makeSSELine(toolCallPayload),
            makeSSELine(finishPayload),
            Data("data: [DONE]\n".utf8)
        ]
    }

    private func makeSSELine(_ payload: Data) -> Data {
        var line = Data("data: ".utf8)
        line.append(payload)
        line.append(Data("\n".utf8))
        return line
    }

    private func makeGitHubWriteArguments() -> String {
        """
        {"owner":"octo","repo":"demo","commit_message":"Add the generated file","changes":[{"path":"Sources/NewFile.swift","operation":"create","content":"print(\\"Hello from Porch\\")\\n"}]}
        """
    }

    private func makeJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
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

    private func requestBodyJSON(for request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        return object
    }

    private func makeJSONObject(from string: String) throws -> [String: Any] {
        let data = try XCTUnwrap(string.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
