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

    func testGitHubContextExposesRecursiveTreeToolAlongsideDirectoryBrowse() async throws {
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
            guard request.url?.host == "server.test" else {
                XCTFail("Unexpected request host: \(request.url?.host ?? "nil")")
                return .data(statusCode: 500)
            }

            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: "GitHub tools are available.", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Inspect the repository"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 2
        }

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.url?.host == "server.test" }))
        let body = try requestBodyJSON(for: request)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let toolNames = tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(toolNames.contains("github_search_paths"))
        XCTAssertTrue(toolNames.contains("github_search_code"))
        XCTAssertTrue(toolNames.contains("github_get_repo_tree"))
        XCTAssertTrue(toolNames.contains("github_get_repo_contents"))
        XCTAssertTrue(toolNames.contains("github_get_file_content"))
        XCTAssertTrue(toolNames.contains("github_get_file_lines"))
        XCTAssertTrue(toolNames.contains("github_get_file_tail"))
        XCTAssertTrue(toolNames.contains("github_list_branches"))
        XCTAssertTrue(toolNames.contains("github_list_commits"))
        XCTAssertTrue(toolNames.contains("github_compare_refs"))
        XCTAssertTrue(toolNames.contains("github_search_issues"))
        XCTAssertTrue(toolNames.contains("github_search_pull_requests"))
        XCTAssertTrue(toolNames.contains("github_get_pull_request_files"))
        XCTAssertTrue(toolNames.contains("github_get_pull_request_diff"))
    }

    func testAutoModeParsesTextToolCallBlocksAndExecutesGitHubTool() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .auto
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0:
                    let body = try self.requestBodyJSON(for: request)
                    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
                    XCTAssertFalse(tools.isEmpty)

                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let toolPrompt = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("You have access to tools. To call a tool") == true)
                    }))
                    let toolPromptContent = try XCTUnwrap(toolPrompt["content"] as? String)
                    XCTAssertTrue(toolPromptContent.contains("<tool_call>"))
                    XCTAssertTrue(toolPromptContent.contains("github_get_repo_tree"))

                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            I'll inspect the repository tree first.

                            <tool_call>
                            {"name":"github_get_repo_tree","arguments":{}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "tool_calls"),
                        Data("data: [DONE]\n".utf8)
                    ])
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Done browsing.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "size": 12]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "From this repo tell me how the GitHub connector works"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Done browsing."
        }

        let treeRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/git/trees/base-tree"
        }
        XCTAssertEqual(treeRequests.count, 1)
        XCTAssertNotNil(harness.chat.sortedMessages.last(where: {
            $0.role == .tool && $0.toolCallName == "github_get_repo_tree"
        }))
    }

    func testPromptBasedModeOmitsNativeToolsAndInjectsToolCallingPrompt() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .promptBased
            },
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
                let body = try self.requestBodyJSON(for: request)
                XCTAssertNil(body["tools"])

                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let toolPrompt = try XCTUnwrap(messages.first(where: {
                    ($0["role"] as? String) == "system" &&
                    (($0["content"] as? String)?.contains("You have access to tools. To call a tool") == true)
                }))
                let toolPromptContent = try XCTUnwrap(toolPrompt["content"] as? String)
                XCTAssertTrue(toolPromptContent.contains("<tool_call>"))
                XCTAssertTrue(toolPromptContent.contains("github_search_paths"))

                return .stream(bodyChunks: [
                    try self.makeSSEChunk(content: "Prompt-based mode is configured.", finishReason: nil),
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ])

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Inspect the repo"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Prompt-based mode is configured."
        }
    }

    func testAutoModeReplaysTextToolCallsAsPromptHistoryOnSubsequentRound() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .auto
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let requestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch requestCounter.next() {
                case 0:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNotNil(body["tools"])
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_search_paths","arguments":{"query":"connector"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 1:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNotNil(body["tools"])
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: { ($0["role"] as? String) == "tool" }))
                    let assistantReplay = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "assistant" &&
                        (($0["content"] as? String)?.contains("<tool_call>") == true)
                    }))
                    let assistantReplayContent = try XCTUnwrap(assistantReplay["content"] as? String)
                    XCTAssertTrue(assistantReplayContent.contains("github_search_paths"))
                    let toolObservation = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("Tool result (github_search_paths)") == true)
                    }))
                    let toolObservationContent = try XCTUnwrap(toolObservation["content"] as? String)
                    XCTAssertTrue(toolObservationContent.contains(#"query="connector""#))
                    XCTAssertTrue(toolObservationContent.contains("Sources/GitHubConnector.swift"))

                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "The connector exposes GitHub search and read tools.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                default:
                    XCTFail("Unexpected extra completion request")
                    return .data(statusCode: 500)
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200],
                        ["path": "Sources/GitHubModels.swift", "mode": "100644", "type": "blob", "size": 180]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Explain the GitHub connector"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "The connector exposes GitHub search and read tools."
        }
    }

    func testPromptBasedModeReplaysPriorToolTurnsAsReadableMessages() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .promptBased
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let requestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch requestCounter.next() {
                case 0:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNil(body["tools"])
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_search_paths","arguments":{"query":"connector"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 1:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNil(body["tools"])
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: { ($0["role"] as? String) == "tool" }))
                    XCTAssertTrue(messages.contains(where: {
                        ($0["role"] as? String) == "assistant" &&
                        (($0["content"] as? String)?.contains("<tool_call>") == true)
                    }))
                    XCTAssertTrue(messages.contains(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("Tool result (github_search_paths)") == true)
                    }))
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Prompt-based replay works.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                default:
                    XCTFail("Unexpected extra completion request")
                    return .data(statusCode: 500)
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Inspect the repo"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "Prompt-based replay works."
        }
    }

    func testPromptBasedGitHubExplanationPromptSwitchesToAnswerOnlyAfterSufficientEvidence() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .promptBased
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let requestCounter = LockedCounter()
        let largeConnectorContent = String(repeating: "connector logic\n", count: 2_000)
        let apiClientContent = "struct GitHubAPIClient { func get() {} }\n"

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch requestCounter.next() {
                case 0:
                    let body = try self.requestBodyJSON(for: request)
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertTrue(messages.contains(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("You have access to tools.") == true)
                    }))
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_search_paths","arguments":{"query":"github connector"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 1:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_get_file_content","arguments":{"path":"Porch/Services/Connectors/GitHub/GitHubConnector.swift"}}
                            </tool_call>
                            <tool_call>
                            {"name":"github_get_file_content","arguments":{"path":"Porch/Services/Connectors/GitHub/GitHubAPIClient.swift"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 2:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNil(body["tools"])
                    XCTAssertEqual(body["tool_choice"] as? String, "none")
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: {
                        (($0["content"] as? String)?.contains("You have access to tools.") == true)
                    }))
                    let answerOnlySummary = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("Answer-only round for GitHub analysis.") == true)
                    }))
                    let answerOnlySummaryContent = try XCTUnwrap(answerOnlySummary["content"] as? String)
                    XCTAssertTrue(answerOnlySummaryContent.contains("The user asked: From this repo tell me how the GitHub connector works"))
                    XCTAssertTrue(answerOnlySummaryContent.contains("Do not call any more tools. Answer now from the evidence already gathered."))
                    let connectorObservation = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("Tool result (github_get_file_content): Read Porch/Services/Connectors/GitHub/GitHubConnector.swift") == true)
                    }))
                    let connectorObservationContent = try XCTUnwrap(connectorObservation["content"] as? String)
                    XCTAssertTrue(connectorObservationContent.contains("Truncated: true"))
                    XCTAssertTrue(connectorObservationContent.contains("File excerpt:"))
                    XCTAssertFalse(connectorObservationContent.contains(String(repeating: "connector logic\n", count: 300)))
                    let toolObservationChars = messages
                        .filter {
                            ($0["role"] as? String) == "system" &&
                            (($0["content"] as? String)?.contains("Tool result (") == true)
                        }
                        .compactMap { ($0["content"] as? String)?.count }
                        .reduce(0, +)
                    XCTAssertLessThanOrEqual(toolObservationChars, 12_000)
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "The GitHub connector is centered in GitHubConnector.swift and delegates HTTP work to GitHubAPIClient.swift.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                default:
                    XCTFail("Unexpected extra completion request")
                    return .data(statusCode: 500)
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "sha": "connector-sha", "size": largeConnectorContent.count],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubAPIClient.swift", "mode": "100644", "type": "blob", "sha": "client-sha", "size": apiClientContent.count]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubConnector.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubConnector.swift",
                    "path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift",
                    "sha": "connector-sha",
                    "content": Data(largeConnectorContent.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": largeConnectorContent.count
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubAPIClient.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubAPIClient.swift",
                    "path": "Porch/Services/Connectors/GitHub/GitHubAPIClient.swift",
                    "sha": "client-sha",
                    "content": Data(apiClientContent.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": apiClientContent.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "From this repo tell me how the GitHub connector works"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "The GitHub connector is centered in GitHubConnector.swift and delegates HTTP work to GitHubAPIClient.swift."
        }
    }

    func testBlankResponseAfterToolUseTriggersOneSynthesisRecoveryRound() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .promptBased
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let requestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch requestCounter.next() {
                case 0:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_search_paths","arguments":{"query":"connector"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 1:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                case 2:
                    let body = try self.requestBodyJSON(for: request)
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let recoveryPrompt = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("You already have tool results in this conversation.") == true)
                    }))
                    let recoveryPromptContent = try XCTUnwrap(recoveryPrompt["content"] as? String)
                    XCTAssertTrue(recoveryPromptContent.contains("Do not return an empty response"))
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Here is the GitHub connector summary.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])

                default:
                    XCTFail("Unexpected extra completion request")
                    return .data(statusCode: 500)
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Explain the GitHub connector"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "Here is the GitHub connector summary."
        }

        let serverRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "server.test" && $0.httpMethod == "POST"
        }
        XCTAssertEqual(serverRequests.count, 3)
    }

    func testRepeatedBlankResponseAfterToolUseSurfacesError() async throws {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        let harness = try makeHarness(
            configureSettings: {
                $0.isGitHubConnectorEnabled = true
                $0.toolCallingMode = .promptBased
            },
            configureChat: {
                $0.applyGitHubContext(
                    GitHubChatContext(owner: "octo", repo: "demo", fullName: "octo/demo", branch: "main")
                )
            },
            keychain: keychain
        )
        let requestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch requestCounter.next() {
                case 0:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(
                            content: """
                            <tool_call>
                            {"name":"github_search_paths","arguments":{"query":"connector"}}
                            </tool_call>
                            """,
                            finishReason: nil
                        ),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                case 1, 2:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                default:
                    XCTFail("Unexpected extra completion request")
                    return .data(statusCode: 500)
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Explain the GitHub connector"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.viewModel.errorMessage == "Model returned an empty response after tool use."
        }
    }

    func testGitHubOutboundMessagesUseCompactGuidanceAndDedupeRepeatedFileReadsByPath() async throws {
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

        let olderFileRead = ChatMessage(
            role: .tool,
            content: #"{"path":"Sources/App.swift","content":"old version"}"#,
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 10),
            toolCallID: "call_old",
            toolCallName: "github_get_file_content",
            toolCallResultJSON: #"{"path":"Sources/App.swift","content":"old version"}"#
        )
        let otherFileRead = ChatMessage(
            role: .tool,
            content: #"{"path":"Sources/Feature.swift","content":"feature version"}"#,
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 20),
            toolCallID: "call_other",
            toolCallName: "github_get_file_content",
            toolCallResultJSON: #"{"path":"Sources/Feature.swift","content":"feature version"}"#
        )
        let latestFileRead = ChatMessage(
            role: .tool,
            content: #"{"path":"Sources/App.swift","content":"new version"}"#,
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 30),
            toolCallID: "call_new",
            toolCallName: "github_get_file_content",
            toolCallResultJSON: #"{"path":"Sources/App.swift","content":"new version"}"#
        )
        let repoTreeResult = ChatMessage(
            role: .tool,
            content: #"{"repository":"octo/demo","entries":[{"path":"Sources/App.swift","kind":"file"}]}"#,
            thread: harness.chat,
            createdAt: Date(timeIntervalSince1970: 40),
            toolCallID: "call_tree",
            toolCallName: "github_get_repo_tree",
            toolCallResultJSON: #"{"repository":"octo/demo","entries":[{"path":"Sources/App.swift","kind":"file"}]}"#
        )
        harness.context.insert(olderFileRead)
        harness.context.insert(otherFileRead)
        harness.context.insert(latestFileRead)
        harness.context.insert(repoTreeResult)
        harness.chat.applyMessageMutation(latestMessage: repoTreeResult)
        try harness.context.save()

        MockURLProtocol.setRequestHandler { request in
            guard request.url?.host == "server.test" else {
                XCTFail("Unexpected request host: \(request.url?.host ?? "nil")")
                return .data(statusCode: 500)
            }

            return .stream(bodyChunks: [
                try self.makeSSEChunk(content: "Done.", finishReason: nil),
                try self.makeSSEChunk(content: nil, finishReason: "stop"),
                Data("data: [DONE]\n".utf8)
            ])
        }

        harness.viewModel.composerText = "Continue"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 6
        }

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.url?.host == "server.test" }))
        let body = try requestBodyJSON(for: request)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        let githubSystemMessage = try XCTUnwrap(messages.first(where: {
            ($0["role"] as? String) == "system" &&
            (($0["content"] as? String)?.contains("GitHub context: octo/demo on branch main.") == true)
        }))
        let githubGuidance = try XCTUnwrap(githubSystemMessage["content"] as? String)
        XCTAssertTrue(githubGuidance.contains("github_search_paths"))
        XCTAssertTrue(githubGuidance.contains("github_get_repo_tree"))
        XCTAssertTrue(githubGuidance.contains("github_get_file_content"))
        XCTAssertTrue(githubGuidance.contains("github_get_file_lines"))
        XCTAssertTrue(githubGuidance.contains("github_get_file_tail"))
        XCTAssertTrue(githubGuidance.contains("github_commit_file_changes"))
        XCTAssertTrue(githubGuidance.contains("Use github_search_paths"))
        XCTAssertTrue(githubGuidance.contains("Avoid rereading the same file path"))
        XCTAssertTrue(githubGuidance.contains("Batch multi-file edits into one github_commit_file_changes call"))
        XCTAssertFalse(githubGuidance.contains("You have access to the GitHub repository"))

        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        let fileReadMessages = toolMessages.filter { ($0["name"] as? String) == "github_get_file_content" }
        XCTAssertEqual(fileReadMessages.count, 2)
        let fileReadContents = fileReadMessages.compactMap { $0["content"] as? String }
        XCTAssertTrue(fileReadContents.contains(#"{"path":"Sources/App.swift","content":"new version"}"#))
        XCTAssertTrue(fileReadContents.contains(#"{"path":"Sources/Feature.swift","content":"feature version"}"#))
        XCTAssertFalse(fileReadContents.contains(#"{"path":"Sources/App.swift","content":"old version"}"#))

        XCTAssertTrue(toolMessages.contains(where: {
            ($0["name"] as? String) == "github_get_repo_tree"
        }))
    }

    func testRepeatedRepoTreeCallInOneRunReturnsAdvisoryInsteadOfHittingGitHubAgain() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0, 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_repo_tree",
                        arguments: "{}"
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Done browsing.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

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
                    "tree": [
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "size": 12]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Inspect the repo"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Done browsing."
        }

        let treeRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/git/trees/base-tree"
        }
        XCTAssertEqual(treeRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool && $0.content.contains("\"status\":\"redundant_call\"")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("\"tool\":\"github_get_repo_tree\""))
        XCTAssertTrue(advisoryToolMessage.content.contains("Reuse the earlier github_get_repo_tree result"))
    }

    func testRepeatedEmptySubtreeScansRedirectToPathSearch() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_repo_tree",
                        arguments: #"{"path_prefix":"src"}"#
                    ))
                case 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_repo_tree",
                        arguments: #"{"path_prefix":"Sources"}"#
                    ))
                case 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_repo_tree",
                        arguments: #"{"path_prefix":"app"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Search by path instead.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Utilities/MessageTimestampFormatter.swift", "mode": "100644", "type": "blob", "size": 100]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Find the formatter"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Search by path instead."
        }

        let treeRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/git/trees/base-tree"
        }
        XCTAssertEqual(treeRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool && $0.content.contains("github_search_paths")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("Stop guessing more missing folders"))
    }

    func testRepeatedFileReadInOneRunReturnsAdvisoryInsteadOfHittingGitHubAgain() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0, 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_file_content",
                        arguments: #"{"path":"Sources/App.swift"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Done reading.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "sha": "app-sha", "size": 12]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Sources/App.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "App.swift",
                    "path": "Sources/App.swift",
                    "sha": "app-sha",
                    "content": Data("print(\"hi\")\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 12
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Read the file"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Done reading."
        }

        let fileRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/contents/Sources/App.swift"
        }
        XCTAssertEqual(fileRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool && $0.content.contains("\"status\":\"redundant_call\"")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("\"tool\":\"github_get_file_content\""))
        XCTAssertTrue(advisoryToolMessage.content.contains("Reuse the earlier github_get_file_content result"))
    }

    func testRepeatedTruncatedFileReadSuggestsFileTailTool() async throws {
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
        let serverRequestCounter = LockedCounter()
        let longContent = String(repeating: "a", count: 12_500)

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0, 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_file_content",
                        arguments: #"{"path":"Sources/Large.swift"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Use the file tail next.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Large.swift", "mode": "100644", "type": "blob", "sha": "large-sha", "size": longContent.count]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Sources/Large.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Large.swift",
                    "path": "Sources/Large.swift",
                    "sha": "large-sha",
                    "content": Data(longContent.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": longContent.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Read the large file"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Use the file tail next."
        }

        let fileRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/contents/Sources/Large.swift"
        }
        XCTAssertEqual(fileRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool && $0.content.contains("\"status\":\"redundant_call\"")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("github_get_file_tail"))
        XCTAssertTrue(advisoryToolMessage.content.contains("truncated"))
    }

    func testRepeatedNearIdenticalPathSearchSuppressesThirdCall() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                case 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"GitHub connector state"}"#
                    ))
                case 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"state connector"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Reuse the earlier path search.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubModels.swift", "mode": "100644", "type": "blob", "size": 190],
                        ["path": "Porch/ViewModels/GitHubContextSelectionViewModel.swift", "mode": "100644", "type": "blob", "size": 175]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Search for connector state"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Reuse the earlier path search."
        }

        let refRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/git/ref/heads/main"
        }
        XCTAssertEqual(refRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool &&
                $0.content.contains("\"status\":\"redundant_call\"") &&
                $0.content.contains("\"tool\":\"github_search_paths\"")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("search family has already been explored"))
        XCTAssertTrue(advisoryToolMessage.content.contains("GitHubConnector.swift"))
    }

    func testRepeatedNearIdenticalCodeSearchSuppressesThirdCall() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_code",
                        arguments: #"{"query":"connector state"}"#
                    ))
                case 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_code",
                        arguments: #"{"query":"GitHub connector state"}"#
                    ))
                case 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_code",
                        arguments: #"{"query":"state connector"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Reuse the earlier code search.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": 200]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubConnector.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubConnector.swift",
                    "path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift",
                    "sha": "sha-1",
                    "content": Data("let connectorState = \"GitHub connector state\"\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 200
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Search the code"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.last?.content == "Reuse the earlier code search."
        }

        let refRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "api.github.com" && $0.url?.path == "/repos/octo/demo/git/ref/heads/main"
        }
        XCTAssertEqual(refRequests.count, 1)

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool &&
                $0.content.contains("\"status\":\"redundant_call\"") &&
                $0.content.contains("\"tool\":\"github_search_code\"")
            })
        )
        XCTAssertTrue(
            advisoryToolMessage.content.contains("search family has already been explored") ||
            advisoryToolMessage.content.contains("same code matches earlier")
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("GitHubConnector.swift"))
    }

    func testAnswerFromEvidenceRequestOmitsGitHubToolsAndUsesTentativeStateHolderGuidance() async throws {
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
        let serverRequestCounter = LockedCounter()
        let sawSynthesisRequest = expectation(description: "Saw synthesis request without GitHub tools")

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                let body = try self.requestBodyJSON(for: request)
                if body["tool_choice"] as? String == "none" {
                    XCTAssertNil(body["tools"])

                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: {
                        (($0["content"] as? String)?.contains("You have access to tools.") == true)
                    }))
                    let synthesisMessage = try XCTUnwrap(messages.first(where: {
                        ($0["role"] as? String) == "system" &&
                        (($0["content"] as? String)?.contains("Confirmed state holders:") == true)
                    }))
                    let guidance = try XCTUnwrap(synthesisMessage["content"] as? String)
                    XCTAssertTrue(guidance.contains("Likely related files:"))
                    XCTAssertTrue(guidance.contains("How they interact:"))
                    XCTAssertTrue(guidance.contains("partial confirmation from file reads"))
                    XCTAssertTrue(guidance.contains("Avoid definitive ownership claims about unread files"))
                    sawSynthesisRequest.fulfill()

                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Answer from prior GitHub evidence.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

                switch serverRequestCounter.next() {
                case 0:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                case 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"GitHub connector state"}"#
                    ))
                case 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                default:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubModels.swift", "mode": "100644", "type": "blob", "size": 190],
                        ["path": "Porch/ViewModels/GitHubContextSelectionViewModel.swift", "mode": "100644", "type": "blob", "size": 175]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Find the files that hold GitHub connector state and summarize how they interact"
        harness.viewModel.sendCurrentInput()

        await fulfillment(of: [sawSynthesisRequest], timeout: 2)

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "Answer from prior GitHub evidence."
        }

        let serverRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == "server.test" && $0.httpMethod == "POST"
        }
        XCTAssertGreaterThanOrEqual(serverRequests.count, 4)
    }

    func testBlockedGitHubToolCallAfterSynthesisModeDoesNotExecuteRemotely() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                case 1:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"GitHub connector state"}"#
                    ))
                case 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_search_paths",
                        arguments: #"{"query":"connector state"}"#
                    ))
                case 3:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNil(body["tools"])
                    XCTAssertEqual(body["tool_choice"] as? String, "none")
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: {
                        (($0["content"] as? String)?.contains("You have access to tools.") == true)
                    }))
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_file_content",
                        arguments: #"{"path":"Porch/Services/Connectors/GitHub/GitHubConnector.swift"}"#
                    ))
                default:
                    let body = try self.requestBodyJSON(for: request)
                    XCTAssertNil(body["tools"])
                    XCTAssertEqual(body["tool_choice"] as? String, "none")
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertFalse(messages.contains(where: {
                        (($0["content"] as? String)?.contains("You have access to tools.") == true)
                    }))
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Answer from existing evidence only.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "size": 200],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubModels.swift", "mode": "100644", "type": "blob", "size": 190]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Find the files that hold GitHub connector state and summarize how they interact"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "Answer from existing evidence only."
        }

        XCTAssertTrue(MockURLProtocol.capturedRequests.allSatisfy {
            $0.url?.path != "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubConnector.swift"
        })

        let advisoryToolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool &&
                $0.content.contains("\"status\":\"tools_disabled\"")
            })
        )
        XCTAssertTrue(advisoryToolMessage.content.contains("\"tool\":\"github_get_file_content\""))
        XCTAssertTrue(advisoryToolMessage.content.contains("must answer from prior evidence"))
    }

    func testGitHubFileLinesToolRepairsMissingBoundsToDefaultWindow() async throws {
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
        let content = ((1...250).map { "line \($0)" }).joined(separator: "\n") + "\n"
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                if serverRequestCounter.next() == 0 {
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_file_lines",
                        arguments: #"{"path":"Sources/App.swift"}"#
                    ))
                }
                return .stream(bodyChunks: [
                    try self.makeSSEChunk(content: "Read the requested line window.", finishReason: nil),
                    try self.makeSSEChunk(content: nil, finishReason: "stop"),
                    Data("data: [DONE]\n".utf8)
                ])

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "sha": "app-sha", "size": content.count]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Sources/App.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "App.swift",
                    "path": "Sources/App.swift",
                    "sha": "app-sha",
                    "content": Data(content.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": content.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Read the file lines"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming &&
            harness.chat.sortedMessages.last?.content == "Read the requested line window."
        }

        let toolMessage = try XCTUnwrap(
            harness.chat.sortedMessages.last(where: {
                $0.role == .tool && $0.toolCallName == "github_get_file_lines"
            })
        )
        let payload = try makeJSONObject(from: toolMessage.content)
        XCTAssertEqual(payload["start_line"] as? Int, 1)
        XCTAssertEqual(payload["end_line"] as? Int, 200)
        XCTAssertEqual(payload["line_count"] as? Int, 200)
        XCTAssertNil(harness.viewModel.errorMessage)
    }

    func testGitHubRedundantCallSuppressionResetsBetweenSeparateUserSends() async throws {
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
        let serverRequestCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (url.host, request.httpMethod, url.path) {
            case ("server.test", "POST", "/v1/chat/completions"):
                switch serverRequestCounter.next() {
                case 0, 2:
                    return .stream(bodyChunks: try self.makeToolCallSSEChunks(
                        toolName: "github_get_file_content",
                        arguments: #"{"path":"Sources/App.swift"}"#
                    ))
                default:
                    return .stream(bodyChunks: [
                        try self.makeSSEChunk(content: "Done.", finishReason: nil),
                        try self.makeSSEChunk(content: nil, finishReason: "stop"),
                        Data("data: [DONE]\n".utf8)
                    ])
                }

            case ("api.github.com", "GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "sha": "app-sha", "size": 12]
                    ]
                ]))

            case ("api.github.com", "GET", "/repos/octo/demo/contents/Sources/App.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "App.swift",
                    "path": "Sources/App.swift",
                    "sha": "app-sha",
                    "content": Data("print(\"hi\")\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 12
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        harness.viewModel.composerText = "Read file once"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 4
        }

        harness.viewModel.composerText = "Read file again in a new request"
        harness.viewModel.sendCurrentInput()

        await waitUntil {
            !harness.viewModel.isStreaming && harness.chat.sortedMessages.count == 8
        }

        let fileToolMessages = harness.chat.sortedMessages.filter {
            $0.role == .tool && $0.toolCallName == "github_get_file_content"
        }
        XCTAssertEqual(fileToolMessages.count, 2)
        XCTAssertFalse(fileToolMessages.contains(where: { $0.content.contains("\"status\":\"redundant_call\"") }))
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
                    toolName: "github_commit_file_changes",
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
                        toolName: "github_commit_file_changes",
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
                        toolName: "github_commit_file_changes",
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
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let viewModel = ChatViewModel(
            chat: chat,
            settings: settings,
            modelContext: context,
            client: client,
            keychain: keychain,
            githubConnector: githubConnector ?? GitHubConnector(
                keychain: keychain,
                session: TestSessionFactory.makeSession(),
                syncCoordinator: GitHubSyncCoordinator(
                    store: GitHubIndexStore(directoryURL: indexDirectory)
                )
            ),
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
        {"commit_message":"Add the generated file","changes":[{"path":"Sources/NewFile.swift","operation":"create","content":"print(\\"Hello from Porch\\")\\n"}]}
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
