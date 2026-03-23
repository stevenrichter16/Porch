import Combine
import Foundation
import os
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.porch.app", category: "Chat")
    private static let streamingPublishInterval = Duration.milliseconds(50)
    private static let maxToolCallRounds = 10

    @Published var composerText = ""
    @Published var nextMessageParameterOverride: GenerationParameters?
    @Published var streamingText = ""
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var pendingGitHubWriteApproval: PendingGitHubWriteApproval?

    private let chat: ChatThread
    private let settings: AppSettings
    private let modelContext: ModelContext
    private let client: OpenAICompatibleClient
    private let keychain: KeychainStoreProtocol
    private let apiKeyAccount = "active-server-api-key"
    private let githubConnector: GitHubConnector
    private let webSearchConnector: WebSearchConnector

    private var streamTask: Task<Void, Never>?
    private var stopRequested = false
    private var pendingGitHubWriteState: PendingGitHubWriteState?

    init(
        chat: ChatThread,
        settings: AppSettings,
        modelContext: ModelContext,
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keychain: KeychainStoreProtocol = KeychainStore(),
        githubConnector: GitHubConnector = GitHubConnector(),
        webSearchConnector: WebSearchConnector = WebSearchConnector()
    ) {
        self.chat = chat
        self.settings = settings
        self.modelContext = modelContext
        self.client = client
        self.keychain = keychain
        self.githubConnector = githubConnector
        self.webSearchConnector = webSearchConnector
    }

    deinit {
        streamTask?.cancel()
    }

    var defaultGenerationParameters: GenerationParameters {
        settings.generationParameters
    }

    func sendCurrentInput() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parameters = nextMessageParameterOverride ?? settings.generationParameters
        nextMessageParameterOverride = nil
        composerText = ""
        send(messageText: trimmed, parameters: parameters)
    }

    func stopGenerating() {
        Self.logger.info("[stop] threadId=\(self.chat.id, privacy: .public)")
        stopRequested = true
        resolvePendingGitHubWriteApproval(with: .stopGeneration)
        streamTask?.cancel()
    }

    func approvePendingGitHubWrite(branchName: String, commitMessage: String) {
        resolvePendingGitHubWriteApproval(
            with: .approve(branchName: branchName, commitMessage: commitMessage)
        )
    }

    func cancelPendingGitHubWriteApproval() {
        resolvePendingGitHubWriteApproval(with: .cancelByUser)
    }

    func regenerateLastResponse() {
        Self.logger.info("[regenerate] threadId=\(self.chat.id, privacy: .public)")
        let persistedMessages = try? ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        guard let messages = persistedMessages, let lastMessage = messages.last, lastMessage.role == .assistant else {
            return
        }

        modelContext.delete(lastMessage)
        let previousLatestMessage = messages.dropLast().last
        chat.applyMessageMutation(latestMessage: previousLatestMessage)
        try? modelContext.save()
        startStreamingConversation(parameters: settings.generationParameters)
    }

    func editUserMessageAndResend(messageID: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isStreaming else { return }

        do {
            let persistedMessages = try ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
            guard
                let targetIndex = persistedMessages.firstIndex(where: { $0.id == messageID }),
                persistedMessages[targetIndex].role == .user
            else {
                errorMessage = "That message could not be edited."
                return
            }

            let targetMessage = persistedMessages[targetIndex]
            let originalContent = targetMessage.content
            let laterMessages = persistedMessages.suffix(from: targetIndex + 1)

            Self.logger.info("[edit] threadId=\(self.chat.id, privacy: .public) messageId=\(messageID, privacy: .public) deletedCount=\(laterMessages.count)")
            targetMessage.content = trimmed
            for laterMessage in laterMessages {
                modelContext.delete(laterMessage)
            }

            if shouldRefreshTitle(
                afterEditingFirstUserMessageAt: targetIndex,
                originalContent: originalContent
            ) {
                chat.title = ChatTitleGenerator.title(for: trimmed)
            }

            chat.applyMessageMutation(latestMessage: targetMessage)
            try modelContext.save()
            startStreamingConversation(parameters: settings.generationParameters)
        } catch {
            Self.logger.error("[edit] threadId=\(self.chat.id, privacy: .public) messageId=\(messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func clearInfo() {
        infoMessage = nil
    }

    private func send(messageText: String, parameters: GenerationParameters) {
        Self.logger.info("[send] threadId=\(self.chat.id, privacy: .public) messageLength=\(messageText.count) model=\(self.chat.modelID, privacy: .public)")
        let userMessage = ChatMessage(role: .user, content: messageText, thread: chat)
        modelContext.insert(userMessage)
        if chat.isUntitled {
            chat.title = ChatTitleGenerator.title(for: messageText)
        }
        chat.applyMessageMutation(latestMessage: userMessage)
        try? modelContext.save()
        startStreamingConversation(parameters: parameters)
    }

    private func startStreamingConversation(parameters: GenerationParameters) {
        Self.logger.info("[startStream] threadId=\(self.chat.id, privacy: .public) model=\(self.chat.modelID, privacy: .public) toolMode=\(String(describing: self.settings.toolCallingMode), privacy: .public)")
        streamTask?.cancel()
        errorMessage = nil
        infoMessage = nil
        streamingText = ""
        isStreaming = true
        stopRequested = false

        do {
            let configuration = try currentServerConfiguration()

            streamTask = Task {
                await runToolCallingLoop(configuration: configuration, parameters: parameters)
                isStreaming = false
                stopRequested = false
                streamTask = nil
            }
        } catch {
            Self.logger.error("[startStream] threadId=\(self.chat.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            isStreaming = false
            errorMessage = error.localizedDescription
        }
    }

    private func runToolCallingLoop(configuration: ServerConfiguration, parameters: GenerationParameters) async {
        var roundsRemaining = Self.maxToolCallRounds
        var isFirstRound = true

        while roundsRemaining > 0 {
            roundsRemaining -= 1
            let currentRound = Self.maxToolCallRounds - roundsRemaining
            Self.logger.info("[toolLoop] threadId=\(self.chat.id, privacy: .public) round=\(currentRound)/\(Self.maxToolCallRounds)")

            do {
                let availableTools = allToolDefinitions()
                let outboundMessages = try buildOutboundMessages(tools: availableTools)
                let tools = resolveToolDefinitions(from: availableTools)
                let descriptor = OpenAIChatRequestDescriptor(
                    configuration: configuration,
                    modelID: chat.modelID,
                    messages: outboundMessages,
                    parameters: parameters,
                    tools: tools
                )

                let result = await streamSingleRound(descriptor: descriptor)

                switch result {
                case .textCompleted(let finishReason):
                    Self.logger.info("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=textCompleted finishReason=\(finishReason?.rawValue ?? "nil", privacy: .public)")
                    if tools != nil && isFirstRound && settings.toolCallingMode == .native {
                        infoMessage = "This model may not support tool calling. Try switching to Auto or Prompt-Based mode in Settings > Connectors."
                    } else {
                        infoMessage = finishReason?.userMessage
                    }
                    return

                case .toolCallsReceived(let toolCalls, let assistantContent):
                    Self.logger.info("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=toolCallsReceived count=\(toolCalls.count) tools=\(toolCalls.map(\.function.name).joined(separator: ","), privacy: .public)")
                    persistAssistantToolCallMessage(content: assistantContent, toolCalls: toolCalls)

                    for toolCall in toolCalls {
                        if stopRequested { return }
                        streamingText = "Calling \(humanReadableToolName(toolCall.function.name))..."
                        guard let result = await executeToolCall(toolCall) else {
                            streamingText = ""
                            return
                        }
                        persistToolResultMessage(toolCall: toolCall, result: result)
                    }
                    streamingText = ""

                case .cancelled:
                    Self.logger.info("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=cancelled")
                    return

                case .error(let error):
                    Self.logger.error("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=error error=\(error.localizedDescription, privacy: .public)")
                    errorMessage = error.localizedDescription
                    return
                }
            } catch {
                Self.logger.error("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=error error=\(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                return
            }

            isFirstRound = false
        }

        // Safety limit reached
        Self.logger.info("[toolLoop] threadId=\(self.chat.id, privacy: .public) result=safetyLimitReached maxRounds=\(Self.maxToolCallRounds)")
        infoMessage = "Stopped after \(Self.maxToolCallRounds) tool-calling rounds."
    }

    private enum RoundResult {
        case textCompleted(ChatFinishReason?)
        case toolCallsReceived([ToolCall], assistantContent: String?)
        case cancelled
        case error(Error)
    }

    private func streamSingleRound(descriptor: OpenAIChatRequestDescriptor) async -> RoundResult {
        var draftText = ""
        var finishReason: ChatFinishReason?
        var receivedToolCalls: [ToolCall]?
        let clock = ContinuousClock()
        var lastPublishedAt = clock.now

        do {
            let stream = await client.streamCompletion(request: descriptor)
            for try await event in stream {
                switch event {
                case .token(let token):
                    draftText.append(token)
                    publishStreamingDraftIfNeeded(
                        draftText,
                        clock: clock,
                        lastPublishedAt: &lastPublishedAt
                    )
                case .toolCalls(let calls):
                    receivedToolCalls = calls
                case .completed(let reason):
                    finishReason = reason
                }
            }

            flushStreamingDraft(draftText)

            if stopRequested {
                persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
                return .cancelled
            }

            // If we received structured tool calls, return them for the loop to handle
            if let toolCalls = receivedToolCalls, !toolCalls.isEmpty {
                let content = draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftText
                streamingText = ""
                return .toolCallsReceived(toolCalls, assistantContent: content)
            }

            // Fallback: try parsing tool calls from text output (for prompt-based/auto modes)
            let mode = settings.toolCallingMode
            if (mode == .promptBased || mode == .auto),
               !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parseResult = TextToolCallParser.parse(draftText)
                if !parseResult.toolCalls.isEmpty {
                    let synthesized = parseResult.toolCalls.map { parsed in
                        ToolCall(
                            id: "text_\(UUID().uuidString.prefix(8))",
                            function: FunctionCall(name: parsed.name, arguments: parsed.arguments)
                        )
                    }
                    let remaining = parseResult.remainingText.isEmpty ? nil : parseResult.remainingText
                    streamingText = ""
                    return .toolCallsReceived(synthesized, assistantContent: remaining)
                }
            }

            // Normal text completion
            persistAssistantDraft(text: draftText, isPartial: false, finishReason: finishReason)
            return .textCompleted(finishReason)

        } catch is CancellationError {
            flushStreamingDraft(draftText)
            persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
            return .cancelled
        } catch {
            flushStreamingDraft(draftText)
            let hadDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hadDraft {
                let persistedReason: ChatFinishReason? = stopRequested ? .cancelled : finishReason
                persistAssistantDraft(text: draftText, isPartial: true, finishReason: persistedReason)
            }
            if stopRequested {
                return .cancelled
            }
            return .error(error)
        }
    }

    /// Returns the full list of available tool definitions regardless of mode.
    /// Used for both API requests (native/auto) and prompt building (promptBased/auto).
    private func allToolDefinitions() -> [ToolDefinition] {
        var tools: [ToolDefinition] = []

        if settings.isWebSearchConnectorEnabled, webSearchConnector.isConfigured {
            tools.append(contentsOf: webSearchConnector.toolDefinitions)
        }

        if settings.isGitHubConnectorEnabled,
           githubConnector.isConfigured,
           let githubContext = chat.githubContext {
            tools.append(contentsOf: githubConnector.toolDefinitions(for: githubContext))
        }

        return tools
    }

    /// Returns tool definitions to send in the API request's `tools` field.
    /// In promptBased mode, returns nil (tools are taught via system prompt instead).
    private func resolveToolDefinitions(from tools: [ToolDefinition]) -> [ToolDefinition]? {
        guard !tools.isEmpty else { return nil }

        switch settings.toolCallingMode {
        case .native, .auto:
            return tools
        case .promptBased:
            return nil
        }
    }

    private func executeToolCall(_ toolCall: ToolCall) async -> String? {
        Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) callId=\(toolCall.id, privacy: .public)")

        if settings.isWebSearchConnectorEnabled,
           webSearchConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
            do {
                let result = try await webSearchConnector.execute(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }
        }

        do {
            guard let githubContext = chat.githubContext else {
                Self.logger.error("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) error=missingGitHubContext")
                return "{\"error\":\"GitHub tools require a selected repository and branch in this chat.\"}"
            }

            if githubConnector.isWriteTool(toolCall.function.name) {
                let request = try await githubConnector.prepareWriteRequest(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments,
                    context: githubContext
                )
                Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) awaitingWriteApproval")
                switch await waitForGitHubWriteApproval(request: request) {
                case .approve(let branchName, let commitMessage):
                    streamingText = "Creating GitHub branch and pushing changes..."
                    let result = try await githubConnector.executeApprovedWrite(
                        request,
                        branchName: branchName,
                        commitMessage: commitMessage
                    )
                    Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) writeApproved branch=\(branchName, privacy: .public)")
                    return try encodeToolResult(result)

                case .cancelByUser:
                    Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) writeCancelledByUser")
                    streamingText = ""
                    return try encodeToolResult(
                        GitHubWriteCancelledResult(reason: "User declined GitHub write approval.")
                    )

                case .stopGeneration:
                    Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) stopGeneration")
                    streamingText = ""
                    return nil
                }
            }

            let result = try await githubConnector.execute(
                toolName: toolCall.function.name,
                arguments: toolCall.function.arguments,
                context: githubContext
            )
            Self.logger.info("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) resultLength=\(result.count)")
            return result
        } catch {
            Self.logger.error("[toolExec] threadId=\(self.chat.id, privacy: .public) tool=\(toolCall.function.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }

    private func persistAssistantToolCallMessage(content: String?, toolCalls: [ToolCall]) {
        // For simplicity, persist the first tool call's metadata on the assistant message.
        // If there are multiple tool calls, they'll each get their own tool result message.
        let encoder = JSONEncoder()
        let toolCallsJSON = (try? encoder.encode(toolCalls)).flatMap { String(data: $0, encoding: .utf8) }

        let assistantMessage = ChatMessage(
            role: .assistant,
            content: content ?? "",
            thread: chat,
            isPartial: false,
            finishReason: .toolCalls,
            toolCallName: toolCalls.first?.function.name,
            toolCallArgumentsJSON: toolCallsJSON
        )
        modelContext.insert(assistantMessage)
        chat.applyMessageMutation(latestMessage: assistantMessage)
        try? modelContext.save()
        streamingText = ""
    }

    private func persistToolResultMessage(toolCall: ToolCall, result: String) {
        let toolMessage = ChatMessage(
            role: .tool,
            content: result,
            thread: chat,
            toolCallID: toolCall.id,
            toolCallName: toolCall.function.name,
            toolCallResultJSON: result
        )
        modelContext.insert(toolMessage)
        chat.applyMessageMutation(latestMessage: toolMessage)
        try? modelContext.save()
    }

    private func currentServerConfiguration() throws -> ServerConfiguration {
        ServerConfiguration(
            baseURL: chat.serverBaseURL,
            apiKey: try keychain.read(account: apiKeyAccount)
        )
    }

    private func buildOutboundMessages(tools: [ToolDefinition]) throws -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
        if !chat.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(OpenAIChatMessage(role: MessageRole.system.rawValue, content: chat.systemPrompt))
        }

        let mode = settings.toolCallingMode
        let githubCtx = (settings.isGitHubConnectorEnabled && githubConnector.isConfigured)
            ? chat.githubContext : nil

        if !tools.isEmpty && (mode == .promptBased || mode == .auto) {
            // Teach the model how to call tools via text output
            let toolPrompt = ToolCallingPromptBuilder.buildPrompt(
                tools: tools,
                githubContext: githubCtx
            )
            messages.append(OpenAIChatMessage(
                role: MessageRole.system.rawValue,
                content: toolPrompt
            ))
        } else if let ctx = githubCtx, !tools.isEmpty {
            messages.append(OpenAIChatMessage(
                role: MessageRole.system.rawValue,
                content: ToolCallingPromptBuilder.githubWorkflowInstructions(for: ctx)
            ))
        }

        let persistedMessages = try ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        for message in persistedMessages {
            switch message.role {
            case .assistant where message.finishReason == .toolCalls:
                // Reconstruct the assistant message with tool_calls
                var toolCalls: [ToolCall] = []
                if let json = message.toolCallArgumentsJSON, let data = json.data(using: .utf8) {
                    toolCalls = (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
                }
                if toolCalls.isEmpty, let name = message.toolCallName {
                    // Fallback: reconstruct a single tool call
                    toolCalls = [ToolCall(id: "call_\(message.id.uuidString.prefix(8))", function: FunctionCall(name: name, arguments: "{}"))]
                }
                let msg = OpenAIChatMessage(
                    role: message.role.rawValue,
                    content: message.content.isEmpty ? nil : message.content,
                    toolCalls: toolCalls
                )
                messages.append(msg)

            case .tool:
                let msg = OpenAIChatMessage(
                    role: message.role.rawValue,
                    content: message.toolCallResultJSON ?? message.content,
                    toolCallID: message.toolCallID ?? "",
                    name: message.toolCallName ?? ""
                )
                messages.append(msg)

            default:
                messages.append(
                    OpenAIChatMessage(
                        role: message.role.rawValue,
                        content: message.content
                    )
                )
            }
        }

        Self.logger.debug("[outbound] threadId=\(self.chat.id, privacy: .public) messageCount=\(messages.count) toolMode=\(String(describing: self.settings.toolCallingMode), privacy: .public)")
        return messages
    }

    private func publishStreamingDraftIfNeeded(
        _ draftText: String,
        clock: ContinuousClock,
        lastPublishedAt: inout ContinuousClock.Instant
    ) {
        let now = clock.now
        guard now - lastPublishedAt >= Self.streamingPublishInterval else {
            return
        }

        flushStreamingDraft(draftText)
        lastPublishedAt = now
    }

    private func flushStreamingDraft(_ draftText: String) {
        guard streamingText != draftText else { return }
        streamingText = draftText
    }

    private func persistAssistantDraft(text: String, isPartial: Bool, finishReason: ChatFinishReason?) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            Self.logger.debug("[persist] threadId=\(self.chat.id, privacy: .public) skipped=emptyDraft")
            streamingText = ""
            return
        }

        Self.logger.debug("[persist] threadId=\(self.chat.id, privacy: .public) role=assistant isPartial=\(isPartial) finishReason=\(finishReason?.rawValue ?? "nil", privacy: .public) contentLength=\(finalText.count)")
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: finalText,
            thread: chat,
            isPartial: isPartial,
            finishReason: finishReason
        )
        modelContext.insert(assistantMessage)
        chat.applyMessageMutation(latestMessage: assistantMessage)
        try? modelContext.save()
        streamingText = ""
    }

    private func shouldRefreshTitle(
        afterEditingFirstUserMessageAt targetIndex: Int,
        originalContent: String
    ) -> Bool {
        guard targetIndex == 0 else { return false }
        return chat.isUntitled || chat.title == ChatTitleGenerator.title(for: originalContent)
    }

    private func humanReadableToolName(_ name: String) -> String {
        let mapping: [String: String] = [
            "web_search": "Web Search",
            "web_fetch_page": "Web Fetch Page",
            "github_search_repos": "GitHub Search",
            "github_get_repo_tree": "GitHub Repo Tree",
            "github_get_repo_contents": "GitHub Browse Files",
            "github_get_file_content": "GitHub Read File",
            "github_list_issues": "GitHub Issues",
            "github_get_issue": "GitHub Issue",
            "github_list_pull_requests": "GitHub Pull Requests",
            "github_get_pull_request": "GitHub Pull Request",
            "github_commit_file_changes": "GitHub Branch & Push"
        ]
        return mapping[name] ?? name
    }

    private func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForGitHubWriteApproval(request: GitHubWriteRequest) async -> GitHubWriteApprovalDecision {
        if stopRequested {
            return .stopGeneration
        }

        let approval = PendingGitHubWriteApproval(request: request)
        pendingGitHubWriteApproval = approval
        streamingText = "Awaiting approval for GitHub changes..."

        return await withCheckedContinuation { continuation in
            pendingGitHubWriteState = PendingGitHubWriteState(
                approvalID: approval.id,
                continuation: continuation
            )
        }
    }

    private func resolvePendingGitHubWriteApproval(with decision: GitHubWriteApprovalDecision) {
        guard let pendingState = pendingGitHubWriteState else { return }
        pendingGitHubWriteState = nil
        pendingGitHubWriteApproval = nil
        pendingState.continuation.resume(returning: decision)
    }

    private struct PendingGitHubWriteState {
        let approvalID: UUID
        let continuation: CheckedContinuation<GitHubWriteApprovalDecision, Never>
    }

    private enum GitHubWriteApprovalDecision {
        case approve(branchName: String, commitMessage: String)
        case cancelByUser
        case stopGeneration
    }
}
