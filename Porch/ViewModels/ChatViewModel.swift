import Combine
import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    private static let streamingPublishInterval = Duration.milliseconds(50)
    private static let maxToolCallRounds = 25
    private static let maxPromptBasedToolReplayChars = 12_000
    private static let maxPromptBasedFileContentReplayChars = 2_000
    private static let maxPromptBasedLineWindowReplayChars = 4_000
    private static let maxPromptBasedSummaryReplayChars = 320
    private static let maxPromptBasedSearchCodeSnippetChars = 400
    private static let logger = PorchLogger(category: "ChatViewModel")

    @Published var composerText = ""
    @Published var nextMessageParameterOverride: GenerationParameters?
    @Published var streamingText = ""
    @Published var streamingThinkingText = ""
    @Published var isModelThinking = false
    @Published var pendingImages: [ImageAttachment] = []
    @Published var isStreaming = false
    @Published var lastTokenUsage: TokenUsage?
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var pendingGitHubWriteApproval: PendingGitHubWriteApproval?
    @Published private(set) var activeGitHubToolActivity: GitHubToolActivity?

    private let chat: ChatThread
    private let settings: AppSettings
    private let modelContext: ModelContext
    private let client: OpenAICompatibleClient
    private let keychain: KeychainStoreProtocol
    private let apiKeyAccount = "active-server-api-key"
    private let githubConnector: GitHubConnector
    private let webSearchConnector: WebSearchConnector
    private let logStoreConnector: LogStoreConnector
    private let memoryConnector: MemoryConnector?
    private var mcpConnectors: [MCPConnector] = []

    private var streamTask: Task<Void, Never>?
    private var stopRequested = false
    private var pendingGitHubWriteState: PendingGitHubWriteState?
    private var gitHubExecutionState = GitHubExecutionState()
    private var toolLoopExecutionState = ToolLoopExecutionState()

    init(
        chat: ChatThread,
        settings: AppSettings,
        modelContext: ModelContext,
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keychain: KeychainStoreProtocol = KeychainStore(),
        githubConnector: GitHubConnector = GitHubConnector(),
        webSearchConnector: WebSearchConnector = WebSearchConnector(),
        logStoreConnector: LogStoreConnector = LogStoreConnector(),
        memoryConnector: MemoryConnector? = nil
    ) {
        self.chat = chat
        self.settings = settings
        self.modelContext = modelContext
        self.client = client
        self.keychain = keychain
        self.githubConnector = githubConnector
        self.webSearchConnector = webSearchConnector
        self.logStoreConnector = logStoreConnector
        self.memoryConnector = memoryConnector
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
        Self.logger.notice("User submitted chat input (\(trimmed.count) chars): \(trimmed)")
        let parameters = nextMessageParameterOverride ?? settings.generationParameters
        nextMessageParameterOverride = nil
        composerText = ""
        send(messageText: trimmed, parameters: parameters)
    }

    func stopGenerating() {
        stopRequested = true
        activeGitHubToolActivity = nil
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
        let persistedMessages = try? ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        guard let messages = persistedMessages, let lastMessage = messages.last, lastMessage.role == .assistant else {
            return
        }

        modelContext.delete(lastMessage)
        let previousLatestMessage = messages.dropLast().last
        chat.applyMessageMutation(latestMessage: previousLatestMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed during regenerateLastResponse: \(error.localizedDescription)")
        }
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
        let images = pendingImages
        pendingImages = []

        let userMessage = ChatMessage(
            role: .user,
            content: messageText,
            thread: chat,
            imageData: images.first?.imageData,
            imageMimeType: images.first?.mimeType
        )
        modelContext.insert(userMessage)
        if chat.isUntitled {
            chat.title = ChatTitleGenerator.title(for: messageText)
        }
        chat.applyMessageMutation(latestMessage: userMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed during send: \(error.localizedDescription)")
        }
        startStreamingConversation(parameters: parameters)
    }

    private func startStreamingConversation(parameters: GenerationParameters) {
        Self.logger.notice("Starting stream for \(self.chat.modelID) temp=\(parameters.temperature) maxTokens=\(parameters.maxTokens) topP=\(parameters.topP) freqPenalty=\(parameters.frequencyPenalty) presPenalty=\(parameters.presencePenalty)")
        streamTask?.cancel()
        errorMessage = nil
        infoMessage = nil
        streamingText = ""
        streamingThinkingText = ""
        isModelThinking = false
        lastTokenUsage = nil
        imageBase64Cache = [:]
        isStreaming = true
        stopRequested = false
        activeGitHubToolActivity = nil
        gitHubExecutionState.reset()
        gitHubExecutionState.configureForPrompt(latestUserPromptText())
        toolLoopExecutionState.reset(for: settings.toolCallingMode)

        do {
            let configuration = try currentServerConfiguration()

            streamTask = Task {
                await runToolCallingLoop(configuration: configuration, parameters: parameters)
                isStreaming = false
                stopRequested = false
                activeGitHubToolActivity = nil
                streamTask = nil
            }
        } catch {
            isStreaming = false
            activeGitHubToolActivity = nil
            errorMessage = error.localizedDescription
        }
    }

    private func runToolCallingLoop(configuration: ServerConfiguration, parameters: GenerationParameters) async {
        // Pre-fetch memories for context injection
        if settings.isMemoryConnectorEnabled, let memoryConnector {
            cachedMemorySnippet = await memoryConnector.memoryContextSnippet()
        }

        // Discover MCP tools from configured servers
        await discoverMCPTools()

        var roundsRemaining = Self.maxToolCallRounds

        while roundsRemaining > 0 {
            roundsRemaining -= 1
            let roundNumber = Self.maxToolCallRounds - roundsRemaining
            gitHubExecutionState.beginRound(roundNumber: roundNumber)
            toolLoopExecutionState.isAnswerOnlyRound = gitHubExecutionState.answerFromEvidenceMode

            do {
                let availableTools = resolveToolDefinitions()
                let outboundMessages = try buildOutboundMessages(toolPromptTools: availableTools)
                let tools = resolveRequestToolDefinitions(from: availableTools)
                let descriptor = OpenAIChatRequestDescriptor(
                    configuration: configuration,
                    modelID: chat.modelID,
                    messages: outboundMessages,
                    parameters: parameters,
                    tools: tools,
                    toolChoice: resolveToolChoice()
                )

                let result = await streamSingleRound(descriptor: descriptor)

                switch result {
                case .textCompleted(let finishReason):
                    Self.logger.notice("Tool loop completed without more tool calls in round \(roundNumber). finishReason=\(String(describing: finishReason))")
                    infoMessage = finishReason?.userMessage
                    return

                case .blankTextAfterToolUse(let finishReason):
                    if toolLoopExecutionState.didAttemptBlankToolResponseRecovery ||
                        toolLoopExecutionState.didAttemptBlockedToolRecovery {
                        Self.logger.error("Tool loop received a repeated blank assistant response after tool use in round \(roundNumber, privacy: .public). finishReason=\(String(describing: finishReason), privacy: .public)")
                        activeGitHubToolActivity = nil
                        errorMessage = "Model returned an empty response after tool use."
                        return
                    }

                    toolLoopExecutionState.didAttemptBlankToolResponseRecovery = true
                    Self.logger.notice("Tool loop is retrying round \(roundNumber + 1, privacy: .public) after a blank assistant response following tool use. finishReason=\(String(describing: finishReason), privacy: .public)")
                    continue

                case .toolCallsReceived(let toolCalls, let assistantContent):
                    let toolNames = toolCalls.map(\.function.name).joined(separator: ", ")
                    Self.logger.notice("Tool loop round \(roundNumber) received \(toolCalls.count) tool call(s): \(toolNames)")
                    if let assistantContent, !assistantContent.isEmpty {
                        Self.logger.debug("Assistant included \(assistantContent.count) characters alongside tool calls in round \(roundNumber)")
                    }

                    if toolLoopExecutionState.isAnswerOnlyRound {
                        persistBlockedToolCallsForAnswerOnlyRound(toolCalls)
                        streamingText = ""
                        activeGitHubToolActivity = nil

                        if toolLoopExecutionState.didAttemptBlockedToolRecovery {
                            Self.logger.error("Stopping tool loop after repeated blocked tool calls in answer-only mode for round \(roundNumber, privacy: .public).")
                            errorMessage = "Model kept requesting tools after being told to answer from existing evidence."
                            return
                        }

                        toolLoopExecutionState.didAttemptBlockedToolRecovery = true
                        Self.logger.notice("Retrying with stricter answer-only guidance after blocked tool calls in round \(roundNumber, privacy: .public).")
                        continue
                    }

                    // Persist the assistant message that requested tool calls
                    persistAssistantToolCallMessage(content: assistantContent, toolCalls: toolCalls)

                    // Execute each tool call and persist results
                    for toolCall in toolCalls {
                        if stopRequested { return }
                        streamingText = "Calling \(humanReadableToolName(toolCall.function.name))..."
                        guard let result = await executeToolCall(toolCall) else {
                            streamingText = ""
                            activeGitHubToolActivity = nil
                            return
                        }
                        persistToolResultMessage(toolCall: toolCall, result: result)
                        activeGitHubToolActivity = nil
                    }
                    streamingText = ""

                    // Refresh memory context if a memory was saved this round
                    if settings.isMemoryConnectorEnabled,
                       let memoryConnector,
                       toolCalls.contains(where: { $0.function.name == "save_memory" }) {
                        cachedMemorySnippet = await memoryConnector.memoryContextSnippet()
                    }

                    activeGitHubToolActivity = nil
                    gitHubExecutionState.finishRoundIfNeeded(logger: Self.logger)
                    toolLoopExecutionState.isAnswerOnlyRound = gitHubExecutionState.answerFromEvidenceMode
                    if gitHubExecutionState.shouldTerminateAfterCurrentRound {
                        Self.logger.warning("Stopping tool loop after repeated blocked GitHub tool calls in synthesis mode.")
                        infoMessage = "Stopped after repeated GitHub tool calls during evidence-based synthesis."
                        return
                    }
                    // Continue the loop for another round

                case .cancelled:
                    Self.logger.notice("Tool loop cancelled in round \(roundNumber)")
                    activeGitHubToolActivity = nil
                    return

                case .error(let error):
                    Self.logger.error("Tool loop failed in round \(roundNumber): \(error.localizedDescription)")
                    activeGitHubToolActivity = nil
                    errorMessage = error.localizedDescription
                    return
                }
            } catch {
                Self.logger.error("Failed to build or run tool loop round \(roundNumber): \(error.localizedDescription)")
                streamingText = ""
                streamingThinkingText = ""
                isModelThinking = false
                activeGitHubToolActivity = nil
                errorMessage = error.localizedDescription
                return
            }
        }

        // Safety limit reached
        Self.logger.warning("Tool loop stopped after reaching max rounds: \(Self.maxToolCallRounds)")
        infoMessage = "Stopped after \(Self.maxToolCallRounds) tool-calling rounds."
    }

    private enum RoundResult {
        case textCompleted(ChatFinishReason?)
        case blankTextAfterToolUse(ChatFinishReason?)
        case toolCallsReceived([ToolCall], assistantContent: String?)
        case cancelled
        case error(Error)
    }

    private func streamSingleRound(descriptor: OpenAIChatRequestDescriptor) async -> RoundResult {
        var draftText = ""
        var finishReason: ChatFinishReason?
        var receivedToolCalls: [ToolCall]?
        var roundUsage: TokenUsage?
        let clock = ContinuousClock()
        var lastPublishedAt = clock.now
        let roundStartTime = clock.now

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
                case .usage(let usage):
                    roundUsage = usage
                    lastTokenUsage = usage
                case .completed(let reason):
                    finishReason = reason
                }
            }

            flushStreamingDraft(draftText)

            if stopRequested {
                printFullStreamedLLMOutput(
                    draftText,
                    finishReason: .cancelled,
                    toolCalls: receivedToolCalls,
                    isPartial: true
                )
                persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
                return .cancelled
            }

            let roundDuration = clock.now - roundStartTime

            // If we received tool calls, return them for the loop to handle
            if let toolCalls = receivedToolCalls, !toolCalls.isEmpty {
                toolLoopExecutionState.recordObservedNativeToolCalls()
                Self.logger.notice("Stream round completed in \(roundDuration) with \(toolCalls.count) native tool call(s), responseLength=\(draftText.count)")
                let content = draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftText
                printFullStreamedLLMOutput(
                    draftText,
                    finishReason: finishReason,
                    toolCalls: toolCalls,
                    isPartial: false
                )
                streamingText = ""
                return .toolCallsReceived(toolCalls, assistantContent: content)
            }

            if let parsedToolCallResult = parseTextToolCallsIfNeeded(
                from: draftText,
                finishReason: finishReason
            ) {
                toolLoopExecutionState.recordObservedPromptBasedToolCalls()
                Self.logger.notice("Stream round completed in \(roundDuration, privacy: .public) with \(parsedToolCallResult.toolCalls.count, privacy: .public) text-parsed tool call(s), responseLength=\(draftText.count, privacy: .public)")
                printFullStreamedLLMOutput(
                    draftText,
                    finishReason: finishReason,
                    toolCalls: parsedToolCallResult.toolCalls,
                    isPartial: false
                )
                streamingText = ""
                return .toolCallsReceived(
                    parsedToolCallResult.toolCalls,
                    assistantContent: parsedToolCallResult.assistantContent
                )
            }

            // Normal text completion
            Self.logger.notice("Stream round completed in \(roundDuration) with text, responseLength=\(draftText.count) finishReason=\(String(describing: finishReason))")
            printFullStreamedLLMOutput(
                draftText,
                finishReason: finishReason,
                toolCalls: nil,
                isPartial: false
            )
            if toolLoopExecutionState.hasPersistedToolResultInCurrentRun,
               draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Self.logger.warning("Ignoring blank assistant completion after tool use and requesting one synthesis retry. finishReason=\(String(describing: finishReason))")
                streamingText = ""
                return .blankTextAfterToolUse(finishReason)
            }
            persistAssistantDraft(text: draftText, isPartial: false, finishReason: finishReason, usage: roundUsage)
            return .textCompleted(finishReason)

        } catch is CancellationError {
            let roundDuration = clock.now - roundStartTime
            Self.logger.notice("Stream round cancelled after \(roundDuration), draftLength=\(draftText.count)")
            flushStreamingDraft(draftText)
            printFullStreamedLLMOutput(
                draftText,
                finishReason: .cancelled,
                toolCalls: receivedToolCalls,
                isPartial: true
            )
            persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
            return .cancelled
        } catch {
            let roundDuration = clock.now - roundStartTime
            Self.logger.error("Stream round failed after \(roundDuration): \(error.localizedDescription) draftLength=\(draftText.count)")
            flushStreamingDraft(draftText)
            let hadDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hadDraft {
                let persistedReason: ChatFinishReason? = stopRequested ? .cancelled : finishReason
                printFullStreamedLLMOutput(
                    draftText,
                    finishReason: persistedReason,
                    toolCalls: receivedToolCalls,
                    isPartial: true
                )
                persistAssistantDraft(text: draftText, isPartial: true, finishReason: persistedReason)
            }
            if stopRequested {
                return .cancelled
            }
            return .error(error)
        }
    }

    private func resolveToolDefinitions() -> [ToolDefinition]? {
        if toolLoopExecutionState.isAnswerOnlyRound {
            Self.logger.notice("Omitting all tools for answer-only round.")
            return nil
        }

        var tools: [ToolDefinition] = []

        let webSearchEnabled = settings.isWebSearchConnectorEnabled
        let webSearchConfigured = webSearchConnector.isConfigured
        if webSearchEnabled, webSearchConfigured {
            tools.append(contentsOf: webSearchConnector.toolDefinitions)
        }

        let githubEnabled = settings.isGitHubConnectorEnabled
        let githubConfigured = githubConnector.isConfigured
        let hasGithubContext = chat.githubContext != nil
        if githubEnabled, githubConfigured, let githubContext = chat.githubContext {
            if gitHubExecutionState.answerFromEvidenceMode {
                Self.logger.notice("Omitting GitHub tools for synthesis round in \(githubContext.repositoryLabel, privacy: .public) branch=\(githubContext.branch, privacy: .public)")
            } else {
                tools.append(contentsOf: githubConnector.toolDefinitions(for: githubContext))
            }
        }

        // Log store is always available for LLM self-debugging
        tools.append(contentsOf: logStoreConnector.toolDefinitions)

        // Memory connector
        if settings.isMemoryConnectorEnabled, let memoryConnector {
            tools.append(contentsOf: memoryConnector.toolDefinitions)
        }

        // MCP connectors
        for mcpConnector in mcpConnectors {
            tools.append(contentsOf: mcpConnector.toolDefinitions)
        }

        Self.logger.debug("Resolved \(tools.count) tools: webSearch=\(webSearchEnabled)/\(webSearchConfigured) github=\(githubEnabled)/\(githubConfigured)/\(hasGithubContext) logStore=true memory=\(settings.isMemoryConnectorEnabled) mcp=\(mcpConnectors.count)")
        return tools.isEmpty ? nil : tools
    }

    private func resolveToolChoice() -> ChatCompletionToolChoice? {
        toolLoopExecutionState.isAnswerOnlyRound || gitHubExecutionState.answerFromEvidenceMode ? ChatCompletionToolChoice.none : nil
    }

    private func resolveRequestToolDefinitions(from availableTools: [ToolDefinition]?) -> [ToolDefinition]? {
        guard let availableTools, !availableTools.isEmpty else {
            return nil
        }

        switch settings.toolCallingMode {
        case .auto, .native:
            return toolLoopExecutionState.isAnswerOnlyRound ? nil : availableTools
        case .promptBased:
            return nil
        }
    }

    private func parseTextToolCallsIfNeeded(
        from draftText: String,
        finishReason: ChatFinishReason?
    ) -> (toolCalls: [ToolCall], assistantContent: String?)? {
        guard settings.toolCallingMode != .native else {
            return nil
        }

        let parsed = TextToolCallParser.parse(draftText)
        guard !parsed.toolCalls.isEmpty else {
            if finishReason == .toolCalls {
                Self.logger.warning("Model reported finish_reason=tool_calls but returned no native or text-parsed tool calls.")
            }
            return nil
        }

        let toolCalls = parsed.toolCalls.enumerated().map { index, parsedToolCall in
            ToolCall(
                id: "call_text_\(index)_\(UUID().uuidString.prefix(8))",
                function: FunctionCall(
                    name: parsedToolCall.name,
                    arguments: parsedToolCall.arguments
                )
            )
        }
        let assistantContent = parsed.remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.notice("Parsed \(toolCalls.count, privacy: .public) text tool call(s) from assistant output in \(self.settings.toolCallingMode.rawValue, privacy: .public) mode.")
        return (
            toolCalls,
            assistantContent: assistantContent.isEmpty ? nil : assistantContent
        )
    }

    private func executeToolCall(_ toolCall: ToolCall) async -> String? {
        let startedAt = Date()
        Self.logger.notice("Executing tool \(toolCall.function.name) callId=\(toolCall.id) args=\(toolCall.function.arguments.prefix(500))")

        if logStoreConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
            do {
                let result = try await logStoreConnector.execute(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                Self.logger.notice("Tool \(toolCall.function.name) completed in \(Self.elapsedMilliseconds(since: startedAt))ms resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("Tool \(toolCall.function.name) failed after \(Self.elapsedMilliseconds(since: startedAt))ms: \(error.localizedDescription)")
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }
        }

        if let memoryConnector,
           memoryConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
            do {
                let result = try await memoryConnector.execute(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                Self.logger.notice("Tool \(toolCall.function.name) completed in \(Self.elapsedMilliseconds(since: startedAt))ms resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("Tool \(toolCall.function.name) failed after \(Self.elapsedMilliseconds(since: startedAt))ms: \(error.localizedDescription)")
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }
        }

        // MCP connectors
        for mcpConnector in mcpConnectors {
            if mcpConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
                do {
                    let result = try await mcpConnector.execute(
                        toolName: toolCall.function.name,
                        arguments: toolCall.function.arguments
                    )
                    Self.logger.notice("MCP tool \(toolCall.function.name) completed in \(Self.elapsedMilliseconds(since: startedAt))ms resultLength=\(result.count)")
                    return result
                } catch {
                    Self.logger.error("MCP tool \(toolCall.function.name) failed after \(Self.elapsedMilliseconds(since: startedAt))ms: \(error.localizedDescription)")
                    return "{\"error\": \"\(error.localizedDescription)\"}"
                }
            }
        }

        if settings.isWebSearchConnectorEnabled,
           webSearchConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
            do {
                let result = try await webSearchConnector.execute(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                Self.logger.notice("Web tool \(toolCall.function.name) completed in \(Self.elapsedMilliseconds(since: startedAt))ms resultBytes=\(result.count)")
                return result
            } catch {
                Self.logger.error("Web tool \(toolCall.function.name) failed after \(Self.elapsedMilliseconds(since: startedAt))ms: \(error.localizedDescription)")
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }
        }

        // Check if this is a GitHub tool before entering the GitHub block
        guard settings.isGitHubConnectorEnabled,
              githubConnector.isConfigured else {
            Self.logger.error("Tool \(toolCall.function.name) not found in any connector callId=\(toolCall.id)")
            return "{\"error\": \"Unknown tool: \(toolCall.function.name)\"}"
        }

        do {
            guard let githubContext = chat.githubContext else {
                Self.logger.error("GitHub tool \(toolCall.function.name) was requested without a selected repo context")
                return "{\"error\":\"GitHub tools require a selected repository and branch in this chat.\"}"
            }

            gitHubExecutionState.markGitHubToolUsed()
            let effectiveArguments = repairGitHubToolArgumentsIfNeeded(
                toolName: toolCall.function.name,
                arguments: toolCall.function.arguments
            )
            activeGitHubToolActivity = GitHubToolActivity(
                toolName: toolCall.function.name,
                arguments: effectiveArguments,
                repositoryLabel: githubContext.repositoryLabel,
                branch: githubContext.branch,
                statusLabel: "Running"
            )
            Self.logger.notice("Executing GitHub tool \(toolCall.function.name) for \(githubContext.repositoryLabel) on branch \(githubContext.branch)")

            if gitHubExecutionState.answerFromEvidenceMode {
                let advisory = GitHubToolAdvisoryResult(
                    status: "tools_disabled",
                    tool: toolCall.function.name,
                    reason: "GitHub tool use is closed for this run because the assistant must answer from prior evidence.",
                    suggested_next_step: "Answer now from the confirmed and inferred GitHub evidence already gathered instead of calling more GitHub tools.",
                    suggested_paths: gitHubExecutionState.synthesisSuggestedPaths
                )
                Self.logger.notice("Blocking GitHub tool \(toolCall.function.name, privacy: .public) because synthesis mode is active for \(githubContext.repositoryLabel, privacy: .public) branch=\(githubContext.branch, privacy: .public)")
                gitHubExecutionState.recordBlockedSynthesisToolCall(
                    toolName: toolCall.function.name,
                    logger: Self.logger
                )
                activeGitHubToolActivity = nil
                return try? encodeToolResult(advisory)
            }

            if let advisoryResult = suppressRedundantGitHubToolCallIfNeeded(
                toolCall,
                effectiveArguments: effectiveArguments,
                context: githubContext
            ) {
                Self.logger.notice("GitHub tool \(toolCall.function.name, privacy: .public) returned advisory in \(Self.elapsedMilliseconds(since: startedAt), privacy: .public)ms")
                activeGitHubToolActivity = nil
                return advisoryResult
            }

            if githubConnector.isWriteTool(toolCall.function.name) {
                let request = try await githubConnector.prepareWriteRequest(
                    toolName: toolCall.function.name,
                    arguments: effectiveArguments,
                    context: githubContext
                )
                Self.logger.notice("Prepared GitHub write request for \(request.repositoryFullName) base=\(request.resolvedBaseRef) proposedBranch=\(request.proposedBranchName) changeCount=\(request.changes.count)")
                activeGitHubToolActivity = GitHubToolActivity(
                    toolName: toolCall.function.name,
                    arguments: effectiveArguments,
                    repositoryLabel: githubContext.repositoryLabel,
                    branch: githubContext.branch,
                    statusLabel: "Awaiting approval"
                )
                switch await waitForGitHubWriteApproval(request: request) {
                case .approve(let branchName, let commitMessage):
                    Self.logger.notice("User approved GitHub write for \(request.repositoryFullName) branch=\(branchName) commitLength=\(commitMessage.count)")
                    activeGitHubToolActivity = GitHubToolActivity(
                        toolName: toolCall.function.name,
                        arguments: effectiveArguments,
                        repositoryLabel: githubContext.repositoryLabel,
                        branch: githubContext.branch,
                        statusLabel: "Pushing changes"
                    )
                    streamingText = "Creating GitHub branch and pushing changes..."
                    let result = try await githubConnector.executeApprovedWrite(
                        request,
                        branchName: branchName,
                        commitMessage: commitMessage
                    )
                    gitHubExecutionState.recordWriteProgress(paths: request.changes.map(\.path))
                    gitHubExecutionState.invalidateValidatedRepositories(for: githubContext)
                    let encodedResult = try encodeToolResult(result)
                    Self.logger.notice("GitHub write completed for \(request.repositoryFullName) branch=\(result.branch_name) commit=\(result.commit_sha) totalMs=\(Self.elapsedMilliseconds(since: startedAt))")
                    activeGitHubToolActivity = nil
                    return encodedResult

                case .cancelByUser:
                    Self.logger.notice("User cancelled GitHub write approval for \(request.repositoryFullName)")
                    streamingText = ""
                    activeGitHubToolActivity = nil
                    let encodedResult = try encodeToolResult(
                        GitHubWriteCancelledResult(reason: "User declined GitHub write approval.")
                    )
                    Self.logger.notice("GitHub write cancelled for \(request.repositoryFullName, privacy: .public) after \(Self.elapsedMilliseconds(since: startedAt), privacy: .public)ms")
                    return encodedResult

                case .stopGeneration:
                    Self.logger.notice("GitHub write approval dismissed because generation was stopped for \(request.repositoryFullName)")
                    streamingText = ""
                    activeGitHubToolActivity = nil
                    return nil
                }
            }

            let executionResult = try await githubConnector.executeDetailed(
                toolName: toolCall.function.name,
                arguments: effectiveArguments,
                context: githubContext,
                validatedRepository: gitHubExecutionState.validatedRepository(for: githubContext)
            )
            if let validatedRepository = executionResult.validatedRepository {
                gitHubExecutionState.cacheValidatedRepository(validatedRepository, for: githubContext)
            }
            recordGitHubToolResultIfNeeded(
                toolName: toolCall.function.name,
                arguments: effectiveArguments,
                result: executionResult.output,
                context: githubContext
            )
            Self.logger.notice("GitHub tool \(toolCall.function.name) completed for \(githubContext.repositoryLabel) in \(Self.elapsedMilliseconds(since: startedAt))ms resultBytes=\(executionResult.output.count)")
            activeGitHubToolActivity = nil
            return executionResult.output
        } catch {
            Self.logger.error("GitHub tool \(toolCall.function.name) failed after \(Self.elapsedMilliseconds(since: startedAt))ms: \(error.localizedDescription)")
            activeGitHubToolActivity = nil
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }

    private func persistAssistantToolCallMessage(content: String?, toolCalls: [ToolCall]) {
        // Persist the full tool-call array for the renderer so it can summarize a single call
        // or a multi-tool batch without losing paths/queries in the collapsed UI.
        let encoder = JSONEncoder()
        let toolCallsJSON = (try? encoder.encode(toolCalls)).flatMap { String(data: $0, encoding: .utf8) }

        let assistantMessage = ChatMessage(
            role: .assistant,
            content: content ?? "",
            thread: chat,
            isPartial: false,
            finishReason: .toolCalls,
            toolCallName: toolCalls.count == 1 ? toolCalls.first?.function.name : "multi_tool_call",
            toolCallArgumentsJSON: toolCallsJSON
        )
        modelContext.insert(assistantMessage)
        chat.applyMessageMutation(latestMessage: assistantMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed in persistAssistantToolCallMessage: \(error.localizedDescription)")
        }
        streamingText = ""
    }

    private func persistToolResultMessage(toolCall: ToolCall, result: String) {
        let toolMessage = ChatMessage(
            role: .tool,
            content: result,
            thread: chat,
            toolCallID: toolCall.id,
            toolCallName: toolCall.function.name,
            toolCallArgumentsJSON: toolCall.function.arguments,
            toolCallResultJSON: result
        )
        modelContext.insert(toolMessage)
        chat.applyMessageMutation(latestMessage: toolMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed in persistToolResultMessage for \(toolCall.function.name): \(error.localizedDescription)")
        }
        toolLoopExecutionState.recordPersistedToolResult()
    }

    private func persistBlockedToolCallsForAnswerOnlyRound(_ toolCalls: [ToolCall]) {
        for toolCall in toolCalls {
            let advisory = BlockedToolCallAdvisoryResult(
                tool: toolCall.function.name,
                reason: "Tool use is disabled for this round because the assistant must answer from evidence already gathered.",
                suggested_next_step: "Answer the user's question directly from the confirmed and inferred evidence already in context. Do not call more tools."
            )
            let encodedResult = (try? encodeToolResult(advisory)) ?? #"{"status":"tools_disabled","tool":"\#(toolCall.function.name)"}"#
            persistToolResultMessage(toolCall: toolCall, result: encodedResult)
        }
    }

    private func currentServerConfiguration() throws -> ServerConfiguration {
        ServerConfiguration(
            baseURL: chat.serverBaseURL,
            apiKey: try keychain.read(account: apiKeyAccount)
        )
    }

    private var cachedMemorySnippet: String?
    private var imageBase64Cache: [UUID: String] = [:]

    private func latestUserPromptText() -> String {
        if let latestUserMessage = chat.sortedMessages.last(where: { $0.role == .user })?.content,
           !latestUserMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return latestUserMessage
        }

        let persistedMessages = try? ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        return persistedMessages?.last(where: { $0.role == .user })?.content ?? ""
    }

    private func buildOutboundMessages(toolPromptTools: [ToolDefinition]?) throws -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
        let usePromptBasedReplay = toolLoopExecutionState.shouldUsePromptBasedReplay(for: settings.toolCallingMode)
        if !chat.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(OpenAIChatMessage(role: MessageRole.system.rawValue, content: chat.systemPrompt))
        }

        // Inject stored memories into context
        if settings.isMemoryConnectorEnabled, let snippet = cachedMemorySnippet, !snippet.isEmpty {
            messages.append(OpenAIChatMessage(
                role: MessageRole.system.rawValue,
                content: snippet
            ))
        }

        if shouldInjectToolCallingPrompt(tools: toolPromptTools),
           let toolPromptTools {
            messages.append(
                OpenAIChatMessage(
                    role: MessageRole.system.rawValue,
                    content: ToolCallingPromptBuilder.buildPrompt(
                        tools: toolPromptTools,
                        githubContext: activeGitHubPromptContext()
                    )
                )
            )
        }

        if settings.isGitHubConnectorEnabled,
           githubConnector.isConfigured,
           let ctx = chat.githubContext {
            messages.append(OpenAIChatMessage(
                role: MessageRole.system.rawValue,
                content: gitHubPromptGuidance(for: ctx)
            ))
            if gitHubExecutionState.answerFromEvidenceMode,
               let synthesisGuidance = gitHubEvidenceSynthesisGuidance(for: ctx) {
                messages.append(OpenAIChatMessage(
                    role: MessageRole.system.rawValue,
                    content: synthesisGuidance
                ))
            }
        }

        if toolLoopExecutionState.isAnswerOnlyRound,
           let answerOnlySummary = promptBasedAnswerOnlySummaryMessage() {
            messages.append(
                OpenAIChatMessage(
                    role: MessageRole.system.rawValue,
                    content: answerOnlySummary
                )
            )
        }

        if toolLoopExecutionState.didAttemptBlankToolResponseRecovery {
            messages.append(
                OpenAIChatMessage(
                    role: MessageRole.system.rawValue,
                    content: """
                    You already have tool results in this conversation. Answer the user's question directly from those tool results. Do not return an empty response. Only call another tool if it is genuinely necessary to finish the answer.
                    """
                )
            )
        }

        if toolLoopExecutionState.didAttemptBlockedToolRecovery {
            messages.append(
                OpenAIChatMessage(
                    role: MessageRole.system.rawValue,
                    content: """
                    Your previous response incorrectly tried to call more tools during an answer-only round. Do not emit any <tool_call> blocks. Answer the user's question directly from the evidence already gathered.
                    """
                )
            )
        }

        let persistedMessages = try ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        let latestFileReadToolMessageIDs = latestGitHubFileReadToolMessageIDs(in: persistedMessages)
        let promptBasedToolReplayContentByID = usePromptBasedReplay
            ? promptBasedToolReplayContents(
                for: persistedMessages,
                latestFileReadToolMessageIDs: latestFileReadToolMessageIDs
            )
            : [:]
        for message in persistedMessages {
            switch message.role {
            case .assistant where message.finishReason == .toolCalls:
                if usePromptBasedReplay {
                    if let replayContent = promptBasedAssistantToolCallReplayContent(for: message) {
                        messages.append(
                            OpenAIChatMessage(
                                role: MessageRole.assistant.rawValue,
                                content: replayContent
                            )
                        )
                    }
                } else {
                    var toolCalls: [ToolCall] = []
                    if let json = message.toolCallArgumentsJSON, let data = json.data(using: .utf8) {
                        toolCalls = (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
                    }
                    if toolCalls.isEmpty, let name = message.toolCallName {
                        toolCalls = [ToolCall(id: "call_\(message.id.uuidString.prefix(8))", function: FunctionCall(name: name, arguments: "{}"))]
                    }
                    let msg = OpenAIChatMessage(
                        role: message.role.rawValue,
                        content: message.content.isEmpty ? nil : message.content,
                        toolCalls: toolCalls
                    )
                    messages.append(msg)
                }

            case .tool:
                if message.toolCallName == "github_get_file_content",
                   !latestFileReadToolMessageIDs.contains(message.id) {
                    continue
                }
                if usePromptBasedReplay {
                    if let replayContent = promptBasedToolReplayContentByID[message.id] {
                        messages.append(
                            OpenAIChatMessage(
                                role: MessageRole.system.rawValue,
                                content: replayContent
                            )
                        )
                    }
                } else {
                    let msg = OpenAIChatMessage(
                        role: message.role.rawValue,
                        content: message.toolCallResultJSON ?? message.content,
                        toolCallID: message.toolCallID ?? "",
                        name: message.toolCallName ?? ""
                    )
                    messages.append(msg)
                }

            default:
                if let imageData = message.imageData,
                   let mimeType = message.imageMimeType {
                    let base64 = imageBase64Cache[message.id] ?? {
                        let encoded = imageData.base64EncodedString()
                        imageBase64Cache[message.id] = encoded
                        return encoded
                    }()
                    let dataURL = "data:\(mimeType);base64,\(base64)"
                    messages.append(OpenAIChatMessage(
                        role: message.role.rawValue,
                        contentParts: [
                            .text(message.content),
                            .imageURL(dataURL)
                        ]
                    ))
                } else {
                    messages.append(
                        OpenAIChatMessage(
                            role: message.role.rawValue,
                            content: message.content
                        )
                    )
                }
            }
        }

        var systemMsgCount = 0, userMsgCount = 0, assistantMsgCount = 0, toolMsgCount = 0, totalChars = 0
        for msg in messages {
            totalChars += msg.content?.count ?? 0
            switch msg.role {
            case MessageRole.system.rawValue: systemMsgCount += 1
            case MessageRole.user.rawValue: userMsgCount += 1
            case MessageRole.assistant.rawValue: assistantMsgCount += 1
            case MessageRole.tool.rawValue: toolMsgCount += 1
            default: break
            }
        }
        let replayStyleLabel = usePromptBasedReplay ? "promptBased" : "native"
        let recoveryActive = toolLoopExecutionState.didAttemptBlankToolResponseRecovery
        Self.logger.notice("Outbound messages: \(messages.count) total (system=\(systemMsgCount) user=\(userMsgCount) assistant=\(assistantMsgCount) tool=\(toolMsgCount)) totalChars=\(totalChars) toolReplay=\(replayStyleLabel) blankRecovery=\(recoveryActive)")
        return messages
    }

    private func promptBasedAssistantToolCallReplayContent(for message: ChatMessage) -> String? {
        let reconstructedToolCalls = reconstructedToolCalls(for: message)
        let toolCallBlocks = reconstructedToolCalls.map(renderPromptBasedToolCallBlock)
        let assistantLeadIn = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = ([assistantLeadIn] + toolCallBlocks).filter { !$0.isEmpty }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private func promptBasedToolResultReplayContent(for message: ChatMessage) -> String? {
        promptBasedToolResultReplayContent(for: message, detailMode: .detailed)
    }

    private func promptBasedToolResultReplayContent(
        for message: ChatMessage,
        detailMode: PromptBasedToolReplayDetailMode
    ) -> String? {
        let toolName = message.toolCallName ?? "tool_result"
        let arguments = message.toolCallArgumentsJSON
        let rawResult = message.toolCallResultJSON ?? message.content
        let serializedResult = serializedPromptBasedToolResult(
            toolName: toolName,
            arguments: arguments,
            rawResult: rawResult,
            detailMode: detailMode
        )
        return serializedResult?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptBasedToolReplayContents(
        for messages: [ChatMessage],
        latestFileReadToolMessageIDs: Set<UUID>
    ) -> [UUID: String] {
        var contentsByID: [UUID: String] = [:]
        var remainingBudget = Self.maxPromptBasedToolReplayChars

        for message in messages.reversed() where shouldIncludeToolMessageInPromptBasedReplay(
            message,
            latestFileReadToolMessageIDs: latestFileReadToolMessageIDs
        ) {
            guard remainingBudget > 0 else { break }

            let detailed = promptBasedToolResultReplayContent(for: message, detailMode: .detailed)
            let summary = promptBasedToolResultReplayContent(for: message, detailMode: .summary)

            if let detailed, detailed.count <= remainingBudget {
                contentsByID[message.id] = detailed
                remainingBudget -= detailed.count
                continue
            }

            guard let summary else { continue }
            let cappedSummary = String(summary.prefix(min(Self.maxPromptBasedSummaryReplayChars, remainingBudget)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cappedSummary.isEmpty else { continue }
            contentsByID[message.id] = cappedSummary
            remainingBudget -= cappedSummary.count
        }

        return contentsByID
    }

    private func shouldIncludeToolMessageInPromptBasedReplay(
        _ message: ChatMessage,
        latestFileReadToolMessageIDs: Set<UUID>
    ) -> Bool {
        guard message.role == .tool else {
            return false
        }
        if message.toolCallName == "github_get_file_content",
           !latestFileReadToolMessageIDs.contains(message.id) {
            return false
        }

        let rawResult = message.toolCallResultJSON ?? message.content
        if let payload = makeJSONObject(from: rawResult),
           let status = payload["status"] as? String,
           ["tools_disabled", "redundant_call", "cancelled"].contains(status) {
            return false
        }

        return true
    }

    private func reconstructedToolCalls(for message: ChatMessage) -> [ToolCall] {
        if let json = message.toolCallArgumentsJSON,
           let data = json.data(using: .utf8),
           let toolCalls = try? JSONDecoder().decode([ToolCall].self, from: data),
           !toolCalls.isEmpty {
            return toolCalls
        }

        guard let toolName = message.toolCallName else {
            return []
        }
        return [
            ToolCall(
                id: "call_\(message.id.uuidString.prefix(8))",
                function: FunctionCall(name: toolName, arguments: "{}")
            )
        ]
    }

    private func renderPromptBasedToolCallBlock(_ toolCall: ToolCall) -> String {
        let argumentsObject: Any
        if let argumentsData = toolCall.function.arguments.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: argumentsData) {
            argumentsObject = jsonObject
        } else {
            argumentsObject = toolCall.function.arguments
        }

        let payload: [String: Any] = [
            "name": toolCall.function.name,
            "arguments": argumentsObject
        ]
        let blockBody: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            blockBody = json
        } else {
            blockBody = #"{"name":"\#(toolCall.function.name)","arguments":\#(toolCall.function.arguments)}"#
        }

        return """
        <tool_call>
        \(blockBody)
        </tool_call>
        """
    }

    private func serializedPromptBasedToolResult(
        toolName: String,
        arguments: String?,
        rawResult: String,
        detailMode: PromptBasedToolReplayDetailMode
    ) -> String? {
        let trimmedResult = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else {
            return "Tool result (\(toolName)): <empty>"
        }

        let argumentObject = arguments.flatMap(makeJSONObject(from:))
        let resultObject = makeJSONObject(from: trimmedResult)

        switch toolName {
        case "github_get_file_content":
            guard let resultObject,
                  let path = resultObject["path"] as? String else {
                return "Tool result (\(toolName)):\n\(trimmedResult)"
            }
            let truncated = gitHubToolResultTruncated(resultObject)
            let sourceSHA = resultObject["source_sha"] as? String
            let fileContent = (resultObject["content"] as? String)?.trimmingCharacters(in: .newlines) ?? ""
            var lines = ["Tool result (\(toolName)): Read \(path)"]
            if let sourceSHA, !sourceSHA.isEmpty {
                lines[0].append(" (sha: \(sourceSHA))")
            }
            lines.append("Truncated: \(truncated ? "true" : "false")")
            if detailMode == .summary {
                let summaryExcerpt = String(fileContent.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !summaryExcerpt.isEmpty {
                    lines.append("Excerpt: \(summaryExcerpt)")
                }
                return lines.joined(separator: "\n")
            }
            let cappedContent: String
            if truncated || fileContent.count > 4_000 {
                cappedContent = String(fileContent.prefix(Self.maxPromptBasedFileContentReplayChars))
            } else {
                cappedContent = fileContent
            }
            if !cappedContent.isEmpty {
                lines.append("File excerpt:")
                lines.append(cappedContent)
            }
            return lines.joined(separator: "\n")

        case "github_get_file_lines", "github_get_file_tail":
            let path = (resultObject?["path"] as? String) ?? (argumentObject?["path"] as? String) ?? "unknown path"
            let startLine = resultObject?["start_line"] as? Int
            let endLine = resultObject?["end_line"] as? Int
            let content = (resultObject?["content"] as? String)?.trimmingCharacters(in: .newlines) ?? trimmedResult
            var header = "Tool result (\(toolName)): Read \(path)"
            if let startLine, let endLine {
                header.append(" lines \(startLine)-\(endLine)")
            }
            let boundedContent = detailMode == .summary
                ? String(content.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
                : String(content.prefix(Self.maxPromptBasedLineWindowReplayChars))
            return boundedContent.isEmpty ? header : "\(header)\n\(boundedContent)"

        case "github_search_paths":
            let query = argumentObject?["query"] as? String
            let results = resultObject?["results"] as? [[String: Any]] ?? []
            let resultLimit = detailMode == .summary ? 3 : 5
            let paths = results.compactMap { $0["path"] as? String }
            var lines = ["Tool result (\(toolName)): matched paths"]
            if let query, !query.isEmpty {
                lines[0] = #"Tool result (\#(toolName)): query="\#(query)""#
            }
            if paths.isEmpty {
                lines.append("No matched paths.")
            } else {
                lines.append("Top matches:")
                lines.append(contentsOf: paths.prefix(resultLimit).map { "- \($0)" })
            }
            return lines.joined(separator: "\n")

        case "github_search_code":
            let query = argumentObject?["query"] as? String
            let results = resultObject?["results"] as? [[String: Any]] ?? []
            var lines = ["Tool result (\(toolName)): code search results"]
            if let query, !query.isEmpty {
                lines[0] = #"Tool result (\#(toolName)): query="\#(query)""#
            }
            if results.isEmpty {
                lines.append("No code matches.")
                return lines.joined(separator: "\n")
            }
            lines.append("Top matches:")
            for result in results.prefix(detailMode == .summary ? 2 : 3) {
                guard let path = result["path"] as? String else { continue }
                let startLine = result["start_line"] as? Int
                let endLine = result["end_line"] as? Int
                let locationSuffix: String
                if let startLine, let endLine {
                    locationSuffix = " lines \(startLine)-\(endLine)"
                } else {
                    locationSuffix = ""
                }
                lines.append("- \(path)\(locationSuffix)")
                if let snippet = result["snippet"] as? String,
                   !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cappedSnippet = detailMode == .summary
                        ? String(trimmedSnippet.prefix(160))
                        : String(trimmedSnippet.prefix(Self.maxPromptBasedSearchCodeSnippetChars))
                    lines.append(cappedSnippet)
                }
            }
            return lines.joined(separator: "\n")

        default:
            if detailMode == .summary {
                let excerpt = String(trimmedResult.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
                return excerpt.isEmpty ? "Tool result (\(toolName))." : "Tool result (\(toolName)): \(excerpt)"
            }
            return "Tool result (\(toolName)):\n\(trimmedResult)"
        }
    }

    private func promptBasedAnswerOnlySummaryMessage() -> String? {
        guard toolLoopExecutionState.isAnswerOnlyRound,
              let context = chat.githubContext,
              let synthesisGuidance = gitHubEvidenceSynthesisGuidance(for: context) else {
            return nil
        }

        let question = gitHubExecutionState.promptIntent.promptText.isEmpty
            ? "the user's GitHub question"
            : gitHubExecutionState.promptIntent.promptText
        let confirmed = gitHubExecutionState.sortedConfirmedSourcePaths
        let inferred = gitHubExecutionState.sortedInferredSourcePaths
        let confirmedSection = confirmed.isEmpty ? "none" : confirmed.prefix(5).joined(separator: ", ")
        let inferredSection = inferred.isEmpty ? "none" : inferred.prefix(5).joined(separator: ", ")

        return """
        Answer-only round for GitHub analysis. The user asked: \(question).
        Confirmed files read: \(confirmedSection).
        Inferred supporting files from search: \(inferredSection).
        Do not call any more tools. Answer now from the evidence already gathered. State what the main files do and how they interact. If evidence is partial, distinguish confirmed findings from likely or inferred ones.

        \(synthesisGuidance)
        """
    }

    private func shouldInjectToolCallingPrompt(tools: [ToolDefinition]?) -> Bool {
        guard !toolLoopExecutionState.isAnswerOnlyRound else {
            return false
        }

        guard let tools, !tools.isEmpty else {
            return false
        }

        switch settings.toolCallingMode {
        case .auto, .promptBased:
            return true
        case .native:
            return false
        }
    }

    private func activeGitHubPromptContext() -> GitHubChatContext? {
        guard settings.isGitHubConnectorEnabled, githubConnector.isConfigured else {
            return nil
        }
        return chat.githubContext
    }

    private enum PromptBasedToolReplayDetailMode {
        case detailed
        case summary
    }

    private func gitHubPromptGuidance(for context: GitHubChatContext) -> String {
        """
        GitHub context: \(context.owner)/\(context.repo) on branch \(context.branch). \
        Use github_search_paths when the user refers to a file conceptually, and use github_get_repo_tree only when you truly need a broad recursive path listing. \
        Reuse earlier tree, github_search_paths, or github_search_code results instead of rescanning the same missing subtree or repeating near-identical searches. \
        For subsystem or architecture questions, do one discovery step, then at most 2 to 4 targeted reads, then answer instead of refining the same search again. \
        Avoid rereading the same file path unless the earlier github_get_file_content result was truncated=true. \
        Use github_get_file_content before updating an existing file, and switch to github_get_file_tail or github_get_file_lines for large files, bottom-of-file edits, or targeted line-range edits. \
        Use github_get_file_lines only for a bounded line window when you know the approximate location; it is not a generic reread fallback for an entire file. \
        Batch multi-file edits into one github_commit_file_changes call by putting all requested file updates inside changes[].
        """
    }

    private func gitHubEvidenceSynthesisGuidance(for context: GitHubChatContext) -> String? {
        let confirmedPaths = gitHubExecutionState.sortedConfirmedSourcePaths
        let inferredPaths = gitHubExecutionState.sortedInferredSourcePaths
        let supportPaths = gitHubExecutionState.sortedSupportEvidencePaths
        let evidencePaths = gitHubExecutionState.sortedEvidencePaths
        guard !evidencePaths.isEmpty else {
            return nil
        }

        let confirmedSection = confirmedPaths.isEmpty ? "none" : confirmedPaths.prefix(5).joined(separator: ", ")
        let inferredSection = inferredPaths.isEmpty ? "none" : inferredPaths.prefix(5).joined(separator: ", ")
        let supportSection = supportPaths.isEmpty ? "none" : supportPaths.prefix(5).joined(separator: ", ")
        let exactQuestion = gitHubExecutionState.promptIntent.promptText.isEmpty
            ? "the user's GitHub question"
            : gitHubExecutionState.promptIntent.promptText

        if gitHubExecutionState.promptIntent.requiresGroundedStateOwnershipAnswer {
            let confidenceInstruction = gitHubExecutionState.requiresTentativeSynthesis
                ? "You only have partial confirmation from file reads. Avoid definitive ownership claims about unread files; use tentative language like 'likely' or 'appears to'."
                : "Make definitive ownership claims only for files in the confirmed section. Files outside that section must still be labeled as inferred if they were not read."
            return """
            GitHub evidence gathered for \(context.repositoryLabel) on branch \(context.branch). \
            Answer the user's exact question: \(exactQuestion). \
            Do not call more GitHub tools. \
            Use this exact structure:
            Confirmed state holders:
            Use only files confirmed by file reads: \(confirmedSection).
            Likely related files:
            Use only inferred files from search results or path matches and label them as inferred: \(inferredSection).
            How they interact:
            Explain interactions clearly, but exclude tests, docs, unrelated connectors, and generic protocol files unless the user explicitly asked for them. \
            \(confidenceInstruction) \
            Support files that may help explain interactions but do not appear to own state: \(supportSection).
            """
        }

        let suggestedFiles = evidencePaths.prefix(8).joined(separator: ", ")
        return """
        GitHub evidence gathered for \(context.repositoryLabel) on branch \(context.branch). \
        Answer the original question now using the prior GitHub tool results instead of calling more GitHub tools. \
        State what the main files do first, then describe how they interact. \
        Use confirmed files first: \(confirmedSection). \
        Mention inferred files only as likely or inferred: \(inferredSection). \
        Support files that may explain interactions but should not be treated as state owners unless confirmed: \(supportSection). \
        Use these paths first: \(suggestedFiles).
        """
    }

    private func latestGitHubFileReadToolMessageIDs(in messages: [ChatMessage]) -> Set<UUID> {
        var latestMessageIDsByPath: [String: UUID] = [:]

        for message in messages where message.role == .tool && message.toolCallName == "github_get_file_content" {
            guard let path = gitHubFileReadPath(from: message) else { continue }
            latestMessageIDsByPath[path] = message.id
        }

        return Set(latestMessageIDsByPath.values)
    }

    private func gitHubFileReadPath(from message: ChatMessage) -> String? {
        let payload = message.toolCallResultJSON ?? message.content
        guard let data = payload.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return jsonObject["path"] as? String
    }

    private func suppressRedundantGitHubToolCallIfNeeded(
        _ toolCall: ToolCall,
        effectiveArguments: String,
        context: GitHubChatContext
    ) -> String? {
        switch toolCall.function.name {
        case "github_get_repo_tree":
            guard let queryKey = gitHubRepoTreeQueryKey(
                from: effectiveArguments,
                branch: context.branch
            ) else {
                return nil
            }
            if let observation = gitHubExecutionState.repoTreeObservations[queryKey] {
                let reason: String
                let nextStep: String
                if observation.wasEmpty {
                    reason = "This repository tree query already returned no matches earlier in this run."
                    nextStep = "Reuse the earlier result and call github_search_paths for conceptual file names instead of rescanning the same missing subtree."
                } else {
                    reason = "This repository tree query already succeeded earlier in this run."
                    nextStep = "Reuse the earlier github_get_repo_tree result already in context, then continue with github_search_paths, github_get_file_content, github_get_file_lines, github_get_file_tail, or github_commit_file_changes."
                }

                let advisory = GitHubToolAdvisoryResult(
                    tool: toolCall.function.name,
                    reason: reason,
                    path_prefix: queryKey.pathPrefix,
                    suggested_next_step: nextStep
                )
                Self.logger.notice("Suppressing redundant GitHub repo tree call for \(context.repositoryLabel, privacy: .public) branch=\(context.branch, privacy: .public) prefix=\(queryKey.pathPrefix ?? "/", privacy: .public)")
                gitHubExecutionState.recordNoProgress(reason: "repo_tree_redundant", logger: Self.logger)
                return try? encodeToolResult(advisory)
            }

            if let pathPrefix = queryKey.pathPrefix,
               gitHubExecutionState.emptyTreePathPrefixes.count >= 2,
               !gitHubExecutionState.didUsePathSearch {
                let advisory = GitHubToolAdvisoryResult(
                    tool: toolCall.function.name,
                    reason: "Multiple subtree scans in this run have already returned no matches.",
                    path_prefix: pathPrefix,
                    suggested_next_step: "Stop guessing more missing folders. Use github_search_paths with the conceptual file name, then read the matched file directly."
                )
                Self.logger.notice("Redirecting repeated empty GitHub subtree scan for \(context.repositoryLabel) branch=\(context.branch) prefix=\(pathPrefix)")
                gitHubExecutionState.recordNoProgress(reason: "repo_tree_empty_redirect", logger: Self.logger)
                return try? encodeToolResult(advisory)
            }

            return nil

        case "github_get_file_content":
            guard let readKey = gitHubFileReadKey(
                from: effectiveArguments,
                branch: context.branch
            ),
            let priorRead = gitHubExecutionState.successfulFileReads[readKey] else {
                return nil
            }

            let suggestedNextStep: String
            let reason: String
            if priorRead.wasTruncated {
                reason = "This file was already read earlier in this run, and the earlier full-file result was truncated."
                suggestedNextStep = "Use github_get_file_tail for this path to inspect the end of the file before appending, or github_get_file_lines for a targeted line range."
            } else {
                reason = "This file was already read earlier in this run."
                suggestedNextStep = "Reuse the earlier github_get_file_content result already in context instead of rereading the same path."
            }

            let advisory = GitHubToolAdvisoryResult(
                tool: toolCall.function.name,
                reason: reason,
                path: readKey.path,
                suggested_next_step: suggestedNextStep
            )
            Self.logger.notice("Suppressing redundant GitHub file read for \(context.repositoryLabel) branch=\(context.branch) path=\(readKey.path) truncated=\(priorRead.wasTruncated)")
            gitHubExecutionState.recordNoProgress(reason: "file_read_redundant", logger: Self.logger)
            return try? encodeToolResult(advisory)

        case "github_search_paths", "github_search_code":
            guard let searchKey = gitHubSearchQueryKey(
                from: effectiveArguments,
                toolName: toolCall.function.name,
                branch: context.branch
            ),
            let observation = gitHubExecutionState.searchObservations[searchKey],
            observation.noProgressRepeatCount >= 1 || observation.executionCount >= 2 else {
                return nil
            }

            let reason: String
            let suggestedNextStep: String
            let isSameSignatureRepeat = observation.noProgressRepeatCount >= 1
            switch (toolCall.function.name, isSameSignatureRepeat) {
            case ("github_search_paths", true):
                reason = "This search query already returned the same path matches earlier in this run."
                suggestedNextStep = "Reuse the earlier github_search_paths result and read one of the matched files directly with github_get_file_content, github_get_file_lines, or github_get_file_tail."
            case ("github_search_paths", false):
                reason = "This search family has already been explored multiple times earlier in this run."
                suggestedNextStep = "Reuse the earlier github_search_paths results, pick one of the suggested files, and switch to targeted file reads instead of refining the same conceptual path search again."
            case ("github_search_code", true):
                reason = "This search query already returned the same code matches earlier in this run."
                suggestedNextStep = "Reuse the earlier github_search_code result and switch to targeted file reads instead of repeating the same search."
            default:
                reason = "This search family has already been explored multiple times earlier in this run."
                suggestedNextStep = "Reuse the earlier github_search_code results, then read the most relevant file directly instead of refining the same conceptual code search again."
            }

            let advisory = GitHubToolAdvisoryResult(
                tool: toolCall.function.name,
                reason: reason,
                suggested_next_step: suggestedNextStep,
                suggested_paths: observation.topPaths.isEmpty ? nil : observation.topPaths
            )
            gitHubExecutionState.incrementSearchAdvisoryCount(for: searchKey)
            let updatedObservation = gitHubExecutionState.searchObservations[searchKey] ?? observation
            Self.logger.notice("Suppressing redundant GitHub search call for \(context.repositoryLabel) branch=\(context.branch) tool=\(toolCall.function.name) query=\(searchKey.normalizedQuery) repeats=\(updatedObservation.noProgressRepeatCount) advisoryCount=\(updatedObservation.advisoryCount)")
            gitHubExecutionState.recordNoProgress(reason: "search_redundant:\(searchKey.normalizedQuery)", logger: Self.logger)
            return try? encodeToolResult(advisory)

        default:
            return nil
        }
    }

    private func recordGitHubToolResultIfNeeded(
        toolName: String,
        arguments: String,
        result: String,
        context: GitHubChatContext
    ) {
        guard let payload = makeJSONObject(from: result) else {
            return
        }
        guard payload["error"] == nil else {
            return
        }

        switch toolName {
        case "github_get_repo_tree":
            guard let queryKey = gitHubRepoTreeQueryKey(from: arguments, branch: context.branch) else {
                return
            }
            let totalMatchingCount = payload["total_matching_count"] as? Int ?? 0
            gitHubExecutionState.repoTreeObservations[queryKey] = GitHubRepoTreeObservation(
                wasEmpty: totalMatchingCount == 0
            )
            if totalMatchingCount == 0 {
                gitHubExecutionState.emptyTreePathPrefixes.insert(queryKey.normalizedPathPrefixForLoopTracking)
                gitHubExecutionState.recordNoProgress(reason: "repo_tree_empty", logger: Self.logger)
            } else {
                let paths = gitHubSearchTopPaths(from: payload, resultKey: "entries", pathKey: "path")
                gitHubExecutionState.recordProgress(
                    evidencePaths: paths,
                    source: .miscellaneous,
                    logger: Self.logger,
                    reason: "repo_tree_success"
                )
            }

        case "github_get_file_content":
            guard let path = payload["path"] as? String else {
                return
            }
            let readKey = GitHubFileReadKey(branch: context.branch, path: path)
            let wasTruncated = gitHubToolResultTruncated(payload)
            gitHubExecutionState.successfulFileReads[readKey] = GitHubFileReadState(wasTruncated: wasTruncated)
            gitHubExecutionState.recordProgress(
                evidencePaths: [path],
                source: .readBacked,
                logger: Self.logger,
                reason: "file_read_success"
            )

        case "github_search_paths":
            gitHubExecutionState.didUsePathSearch = true
            fallthrough

        case "github_search_code":
            guard let searchKey = gitHubSearchQueryKey(
                from: arguments,
                toolName: toolName,
                branch: context.branch
            ),
            let resultSignature = gitHubSearchResultSignature(
                toolName: toolName,
                payload: payload
            ) else {
                return
            }
            let topPaths = gitHubSearchTopPaths(from: payload, resultKey: "results", pathKey: "path")
            let hasUsefulSearchResults = !topPaths.isEmpty

            if var observation = gitHubExecutionState.searchObservations[searchKey] {
                if observation.resultSignature == resultSignature {
                    observation.executionCount += 1
                    observation.noProgressRepeatCount += 1
                    observation.topPaths = topPaths
                    gitHubExecutionState.searchObservations[searchKey] = observation
                    gitHubExecutionState.recordNoProgress(
                        reason: "search_same_signature:\(searchKey.normalizedQuery)",
                        logger: Self.logger
                    )
                } else {
                    observation.executionCount += 1
                    observation.resultSignature = resultSignature
                    observation.noProgressRepeatCount = 0
                    observation.topPaths = topPaths
                    observation.lastProgressRound = gitHubExecutionState.currentRoundNumber
                    gitHubExecutionState.searchObservations[searchKey] = observation
                    if hasUsefulSearchResults {
                        gitHubExecutionState.recordProgress(
                            evidencePaths: topPaths,
                            source: .searchBacked,
                            logger: Self.logger,
                            reason: "search_new_results:\(searchKey.normalizedQuery)"
                        )
                    } else {
                        gitHubExecutionState.recordNoProgress(
                            reason: "search_empty_results:\(searchKey.normalizedQuery)",
                            logger: Self.logger
                        )
                    }
                }
            } else {
                gitHubExecutionState.searchObservations[searchKey] = GitHubSearchObservation(
                    resultSignature: resultSignature,
                    noProgressRepeatCount: 0,
                    topPaths: topPaths,
                    advisoryCount: 0,
                    lastProgressRound: gitHubExecutionState.currentRoundNumber,
                    executionCount: 1
                )
                if hasUsefulSearchResults {
                    gitHubExecutionState.recordProgress(
                        evidencePaths: topPaths,
                        source: .searchBacked,
                        logger: Self.logger,
                        reason: "search_initial_results:\(searchKey.normalizedQuery)"
                    )
                } else {
                    gitHubExecutionState.recordNoProgress(
                        reason: "search_empty_results:\(searchKey.normalizedQuery)",
                        logger: Self.logger
                    )
                }
            }

        default:
            break
        }
    }

    private func gitHubRepoTreeQueryKey(from arguments: String, branch: String) -> GitHubRepoTreeQueryKey? {
        guard let payload = makeJSONObject(from: arguments) else {
            return nil
        }

        let normalizedPrefix = normalizeGitHubTreePathPrefix(payload["path_prefix"] as? String)
        let entryType: String
        if let rawEntryType = payload["entry_type"] as? String {
            let normalizedEntryType = rawEntryType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["all", "files", "directories"].contains(normalizedEntryType) else {
                return nil
            }
            entryType = normalizedEntryType
        } else {
            entryType = "all"
        }

        let rawMaxEntries = payload["max_entries"] as? Int ?? 400
        guard rawMaxEntries > 0 else {
            return nil
        }
        let maxEntries = min(rawMaxEntries, 1_000)

        return GitHubRepoTreeQueryKey(
            branch: branch,
            pathPrefix: normalizedPrefix,
            entryType: entryType,
            maxEntries: maxEntries
        )
    }

    private func gitHubFileReadKey(from arguments: String, branch: String) -> GitHubFileReadKey? {
        guard let payload = makeJSONObject(from: arguments),
              let rawPath = payload["path"] as? String
        else {
            return nil
        }

        let normalizedPath = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else {
            return nil
        }

        return GitHubFileReadKey(branch: branch, path: normalizedPath)
    }

    private func repairGitHubToolArgumentsIfNeeded(
        toolName: String,
        arguments: String
    ) -> String {
        guard toolName == "github_get_file_lines",
              var payload = makeJSONObject(from: arguments),
              let rawPath = payload["path"] as? String,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return arguments
        }

        let hasStartLine = payload["start_line"] is Int
        let hasEndLine = payload["end_line"] is Int

        switch (hasStartLine, hasEndLine) {
        case (false, false):
            payload["start_line"] = 1
            payload["end_line"] = 200

        case (true, false):
            if let startLine = payload["start_line"] as? Int {
                payload["end_line"] = startLine + 199
            }

        case (false, true):
            if let endLine = payload["end_line"] as? Int {
                payload["start_line"] = max(1, endLine - 199)
            }

        case (true, true):
            break
        }

        guard let repairedArguments = jsonString(from: payload) else {
            return arguments
        }

        if repairedArguments != arguments {
            Self.logger.notice("Repaired github_get_file_lines arguments to a bounded line window before execution.")
        }
        return repairedArguments
    }

    private func gitHubSearchQueryKey(
        from arguments: String,
        toolName: String,
        branch: String
    ) -> GitHubSearchQueryKey? {
        guard let payload = makeJSONObject(from: arguments),
              let rawQuery = payload["query"] as? String,
              let normalizedQuery = GitHubSearchNormalizer.normalizeQueryFamily(rawQuery) else {
            return nil
        }

        return GitHubSearchQueryKey(
            branch: branch,
            tool: toolName,
            normalizedQuery: normalizedQuery
        )
    }

    private func searchQueryTokens(for value: String) -> [String] {
        GitHubSearchNormalizer.tokenize(value)
    }

    private func gitHubSearchResultSignature(
        toolName: String,
        payload: [String: Any]
    ) -> String? {
        guard let results = payload["results"] as? [[String: Any]] else {
            return nil
        }

        switch toolName {
        case "github_search_paths":
            let signatureItems = results.compactMap { result in
                result["path"] as? String
            }
            return signatureItems.joined(separator: "|")

        case "github_search_code":
            let signatureItems = results.compactMap { result -> String? in
                guard let path = result["path"] as? String else {
                    return nil
                }
                let startLine = result["start_line"] as? Int ?? 0
                let endLine = result["end_line"] as? Int ?? 0
                return "\(path):\(startLine):\(endLine)"
            }
            return signatureItems.joined(separator: "|")

        default:
            return nil
        }
    }

    private func gitHubSearchTopPaths(
        from payload: [String: Any],
        resultKey: String,
        pathKey: String
    ) -> [String] {
        let results = payload[resultKey] as? [[String: Any]] ?? []
        return Array(results.compactMap { $0[pathKey] as? String }.prefix(5))
    }

    private func normalizeGitHubTreePathPrefix(_ rawPrefix: String?) -> String? {
        guard let rawPrefix else { return nil }

        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }

        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else {
            return nil
        }
        guard !components.contains("."),
              !components.contains(".."),
              !components.contains(".git") else {
            return nil
        }

        return components.joined(separator: "/")
    }

    private func gitHubToolResultTruncated(_ payload: [String: Any]) -> Bool {
        if let value = payload["truncated"] as? Bool {
            return value
        }
        if let value = payload["truncated"] as? String {
            return value == "true"
        }
        return false
    }

    private func makeJSONObject(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func jsonString(from object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
        let isThinking = ThinkingContentParser.isInsideThinkBlock(draftText)
        isModelThinking = isThinking

        if isThinking {
            // While inside a think block, show the thinking content being generated
            let parsed = ThinkingContentParser.parse(draftText)
            // The unclosed think block is at the end — extract it
            let thinkingInProgress = extractOpenThinkBlock(from: draftText)
            streamingThinkingText = parsed.thinking.isEmpty ? thinkingInProgress : parsed.thinking + "\n\n" + thinkingInProgress
            streamingText = parsed.visible
        } else {
            let parsed = ThinkingContentParser.parse(draftText)
            streamingThinkingText = parsed.thinking
            streamingText = parsed.visible
        }
    }

    private func extractOpenThinkBlock(from text: String) -> String {
        // Find the last open <think> or <thinking> tag without a matching close
        let patterns: [(open: String, close: String)] = [
            ("<think>", "</think>"),
            ("<thinking>", "</thinking>")
        ]

        for (open, close) in patterns {
            if let openRange = text.range(of: open, options: .backwards) {
                let afterOpen = text[openRange.upperBound...]
                if afterOpen.range(of: close) == nil {
                    return String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return ""
    }

    private func printFullStreamedLLMOutput(
        _ draftText: String,
        finishReason: ChatFinishReason?,
        toolCalls: [ToolCall]?,
        isPartial: Bool
    ) {
        let toolCallCount = toolCalls?.count ?? 0
        let renderedText = draftText.isEmpty ? "<empty>" : draftText
        print("[LLM streamed output] partial=\(isPartial) finishReason=\(finishReason?.apiValue ?? "nil") toolCalls=\(toolCallCount)")
        print("[LLM streamed output begin]")
        print(renderedText)
        print("[LLM streamed output end]")
    }

    private func persistAssistantDraft(text: String, isPartial: Bool, finishReason: ChatFinishReason?, usage: TokenUsage? = nil) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            streamingText = ""
            streamingThinkingText = ""
            isModelThinking = false
            return
        }

        // Separate thinking content from visible content
        let parsed = ThinkingContentParser.parse(finalText)
        let visibleContent = parsed.visible
        let thinkingContent = parsed.thinking.isEmpty ? nil : parsed.thinking

        // If the model produced only thinking with no visible answer, persist it
        // with empty content so the thinking is still accessible
        guard !visibleContent.isEmpty || thinkingContent != nil else {
            streamingText = ""
            streamingThinkingText = ""
            isModelThinking = false
            return
        }

        let assistantMessage = ChatMessage(
            role: .assistant,
            content: visibleContent,
            thread: chat,
            isPartial: isPartial,
            finishReason: finishReason,
            thinkingContent: thinkingContent,
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens
        )
        modelContext.insert(assistantMessage)
        chat.applyMessageMutation(latestMessage: assistantMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed in persistAssistantDraft: \(error.localizedDescription)")
        }
        streamingText = ""
        streamingThinkingText = ""
        isModelThinking = false
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
            "github_search_paths": "GitHub Search Paths",
            "github_search_code": "GitHub Search Code",
            "github_get_repo_tree": "GitHub Repo Tree",
            "github_get_repo_contents": "GitHub Browse Files",
            "github_get_file_content": "GitHub Read File",
            "github_get_file_lines": "GitHub Read File Lines",
            "github_get_file_tail": "GitHub Read File Tail",
            "github_list_branches": "GitHub Branches",
            "github_list_commits": "GitHub Commits",
            "github_compare_refs": "GitHub Compare Refs",
            "github_list_issues": "GitHub Issues",
            "github_search_issues": "GitHub Search Issues",
            "github_get_issue": "GitHub Issue",
            "github_list_pull_requests": "GitHub Pull Requests",
            "github_search_pull_requests": "GitHub Search Pull Requests",
            "github_get_pull_request": "GitHub Pull Request",
            "github_get_pull_request_files": "GitHub Pull Request Files",
            "github_get_pull_request_diff": "GitHub Pull Request Diff",
            "github_commit_file_changes": "GitHub Branch & Push"
        ]
        return mapping[name] ?? name
    }

    private func discoverMCPTools() async {
        mcpConnectors = []
        let enabledConfigs = settings.mcpServerConfigs.filter(\.isEnabled)
        guard !enabledConfigs.isEmpty else { return }

        for config in enabledConfigs {
            guard let url = URL(string: config.url) else { continue }
            var headers: [String: String] = [:]
            if let auth = config.authorizationHeader {
                headers["Authorization"] = auth
            }

            let connector = MCPConnector(
                serverURL: url,
                displayName: config.name,
                headers: headers
            )

            do {
                // Timeout after 5 seconds to avoid blocking the first message
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await connector.discoverTools() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }
                mcpConnectors.append(connector)
                Self.logger.notice("MCP server \(config.name) discovered \(connector.toolDefinitions.count) tools")
            } catch {
                Self.logger.error("MCP server \(config.name) discovery failed or timed out: \(error.localizedDescription)")
            }
        }
    }

    private func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private func waitForGitHubWriteApproval(request: GitHubWriteRequest) async -> GitHubWriteApprovalDecision {
        if stopRequested {
            Self.logger.notice("Skipping GitHub write approval because generation is already stopping for \(request.repositoryFullName)")
            return .stopGeneration
        }

        let approval = PendingGitHubWriteApproval(request: request)
        Self.logger.notice("Presenting GitHub write approval for \(approval.repositoryFullName) base=\(approval.resolvedBaseRef) proposedBranch=\(approval.proposedBranchName) created=\(approval.createdCount) updated=\(approval.updatedCount) deleted=\(approval.deletedCount)")
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
        let decisionLabel: String
        switch decision {
        case .approve(let branchName, _):
            decisionLabel = "approve(\(branchName))"
        case .cancelByUser:
            decisionLabel = "cancelByUser"
        case .stopGeneration:
            decisionLabel = "stopGeneration"
        }
        Self.logger.notice("Resolving GitHub write approval \(pendingState.approvalID.uuidString) with decision \(decisionLabel)")
        pendingGitHubWriteState = nil
        pendingGitHubWriteApproval = nil
        pendingState.continuation.resume(returning: decision)
    }

    private struct PendingGitHubWriteState {
        let approvalID: UUID
        let continuation: CheckedContinuation<GitHubWriteApprovalDecision, Never>
    }

    struct GitHubToolActivity: Equatable, Sendable {
        var toolName: String
        var arguments: String
        var repositoryLabel: String
        var branch: String
        var statusLabel: String
    }

    private enum GitHubWriteApprovalDecision {
        case approve(branchName: String, commitMessage: String)
        case cancelByUser
        case stopGeneration
    }

    private struct GitHubPromptIntent {
        var promptText: String = ""
        var requiresGroundedStateOwnershipAnswer = false
        var prefersAnswerAfterSufficientEvidence = false

        init(promptText: String = "") {
            let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.promptText = trimmedPrompt

            let tokens = Set(GitHubSearchNormalizer.tokenize(trimmedPrompt))
            let lowercasedPrompt = trimmedPrompt.lowercased()
            let stateTokens: Set<String> = [
                "state", "context", "settings", "selection", "session", "store",
                "stores", "model", "models", "viewmodel", "viewmodels", "cache", "index"
            ]
            let ownershipTokens: Set<String> = [
                "hold", "holds", "holding", "own", "owns", "owned",
                "live", "lives", "where", "does"
            ]
            let architectureTokens: Set<String> = [
                "interact", "interaction", "summarize", "summary", "architecture", "flow", "relationship"
            ]

            let hasStateSignal = !tokens.isDisjoint(with: stateTokens)
            let hasOwnershipSignal =
                !tokens.isDisjoint(with: ownershipTokens) ||
                lowercasedPrompt.contains("where does")
            let hasArchitectureSignal = !tokens.isDisjoint(with: architectureTokens)
            requiresGroundedStateOwnershipAnswer = hasStateSignal && (hasOwnershipSignal || hasArchitectureSignal)
            prefersAnswerAfterSufficientEvidence =
                lowercasedPrompt.contains("tell me how") ||
                lowercasedPrompt.contains("how does") ||
                lowercasedPrompt.contains("explain") ||
                lowercasedPrompt.contains("summarize") ||
                (tokens.contains("how") && (tokens.contains("work") || tokens.contains("works")))
        }
    }

    private enum GitHubEvidenceSource {
        case readBacked
        case searchBacked
        case miscellaneous
    }

    private enum ToolReplayStyle {
        case native
        case promptBased
    }

    private struct ToolLoopExecutionState {
        var replayStyle: ToolReplayStyle?
        var hasPersistedToolResultInCurrentRun = false
        var didAttemptBlankToolResponseRecovery = false
        var didAttemptBlockedToolRecovery = false
        var didUsePromptBasedToolCalling = false
        var isAnswerOnlyRound = false

        mutating func reset(for mode: ToolCallingMode) {
            switch mode {
            case .native:
                replayStyle = .native
            case .promptBased:
                replayStyle = .promptBased
            case .auto:
                replayStyle = nil
            }
            hasPersistedToolResultInCurrentRun = false
            didAttemptBlankToolResponseRecovery = false
            didAttemptBlockedToolRecovery = false
            didUsePromptBasedToolCalling = false
            isAnswerOnlyRound = false
        }

        mutating func recordObservedNativeToolCalls() {
            if replayStyle == nil {
                replayStyle = .native
            }
        }

        mutating func recordObservedPromptBasedToolCalls() {
            replayStyle = .promptBased
            didUsePromptBasedToolCalling = true
        }

        mutating func recordPersistedToolResult() {
            hasPersistedToolResultInCurrentRun = true
        }

        func shouldUsePromptBasedReplay(for mode: ToolCallingMode) -> Bool {
            switch mode {
            case .native:
                return false
            case .promptBased:
                return true
            case .auto:
                return didUsePromptBasedToolCalling || replayStyle == .promptBased
            }
        }
    }

    private struct BlockedToolCallAdvisoryResult: Encodable {
        var status: String = "tools_disabled"
        var tool: String
        var reason: String
        var suggested_next_step: String
    }

    private struct GitHubExecutionState {
        var repoTreeObservations: [GitHubRepoTreeQueryKey: GitHubRepoTreeObservation] = [:]
        var successfulFileReads: [GitHubFileReadKey: GitHubFileReadState] = [:]
        var searchObservations: [GitHubSearchQueryKey: GitHubSearchObservation] = [:]
        var emptyTreePathPrefixes: Set<String> = []
        var evidencePaths: Set<String> = []
        var confirmedSourcePaths: Set<String> = []
        var inferredSourcePaths: Set<String> = []
        var supportEvidencePaths: Set<String> = []
        var subsystemAnchorTokens: Set<String> = []
        var validatedRepositories: [GitHubValidatedRepositoryKey: GitHubIndexedRepository] = [:]
        var promptIntent = GitHubPromptIntent()
        var consecutiveNoProgressGitHubRounds = 0
        var hasSuccessfulGitHubResult = false
        var answerFromEvidenceMode = false
        var requiresTentativeSynthesis = false
        var didUsePathSearch = false
        var blockedSynthesisToolCallCount = 0
        var shouldTerminateAfterCurrentRound = false
        var currentRoundNumber = 0
        var currentRoundUsedGitHubTool = false
        var currentRoundMadeProgress = false

        mutating func reset() {
            repoTreeObservations.removeAll(keepingCapacity: false)
            successfulFileReads.removeAll(keepingCapacity: false)
            searchObservations.removeAll(keepingCapacity: false)
            emptyTreePathPrefixes.removeAll(keepingCapacity: false)
            evidencePaths.removeAll(keepingCapacity: false)
            confirmedSourcePaths.removeAll(keepingCapacity: false)
            inferredSourcePaths.removeAll(keepingCapacity: false)
            supportEvidencePaths.removeAll(keepingCapacity: false)
            subsystemAnchorTokens.removeAll(keepingCapacity: false)
            validatedRepositories.removeAll(keepingCapacity: false)
            promptIntent = GitHubPromptIntent()
            consecutiveNoProgressGitHubRounds = 0
            hasSuccessfulGitHubResult = false
            answerFromEvidenceMode = false
            requiresTentativeSynthesis = false
            didUsePathSearch = false
            blockedSynthesisToolCallCount = 0
            shouldTerminateAfterCurrentRound = false
            currentRoundNumber = 0
            currentRoundUsedGitHubTool = false
            currentRoundMadeProgress = false
        }

        mutating func configureForPrompt(_ promptText: String) {
            promptIntent = GitHubPromptIntent(promptText: promptText)
        }

        mutating func beginRound(roundNumber: Int) {
            currentRoundNumber = roundNumber
            currentRoundUsedGitHubTool = false
            currentRoundMadeProgress = false
            shouldTerminateAfterCurrentRound = false
        }

        mutating func markGitHubToolUsed() {
            currentRoundUsedGitHubTool = true
        }

        mutating func recordProgress(
            evidencePaths newPaths: [String],
            source: GitHubEvidenceSource,
            logger: Logger,
            reason: String
        ) {
            currentRoundMadeProgress = true
            hasSuccessfulGitHubResult = true
            classifyEvidence(newPaths, source: source)
            let roundNumber = currentRoundNumber
            let previewPaths = Array(newPaths.prefix(5)).joined(separator: ", ")
            logger.debug("GitHub progress classified in round \(roundNumber, privacy: .public) reason=\(reason, privacy: .public) evidencePaths=\(previewPaths, privacy: .public)")
        }

        mutating func recordWriteProgress(paths: [String]) {
            hasSuccessfulGitHubResult = true
            currentRoundUsedGitHubTool = true
            currentRoundMadeProgress = true
            evidencePaths.formUnion(paths)
        }

        mutating func recordNoProgress(reason: String, logger: Logger) {
            currentRoundUsedGitHubTool = true
            let roundNumber = currentRoundNumber
            logger.debug("GitHub no-progress classified in round \(roundNumber, privacy: .public) reason=\(reason, privacy: .public)")
        }

        mutating func recordBlockedSynthesisToolCall(toolName: String, logger: Logger) {
            currentRoundUsedGitHubTool = true
            blockedSynthesisToolCallCount += 1
            if blockedSynthesisToolCallCount >= 2 {
                shouldTerminateAfterCurrentRound = true
            }
            let roundNumber = currentRoundNumber
            let blockedCount = blockedSynthesisToolCallCount
            logger.debug("Blocked GitHub tool \(toolName, privacy: .public) during synthesis mode in round \(roundNumber, privacy: .public) blockedCount=\(blockedCount, privacy: .public)")
        }

        mutating func incrementSearchAdvisoryCount(for key: GitHubSearchQueryKey) {
            guard var observation = searchObservations[key] else { return }
            observation.advisoryCount += 1
            searchObservations[key] = observation
        }

        mutating func cacheValidatedRepository(_ repository: GitHubIndexedRepository, for context: GitHubChatContext) {
            validatedRepositories[GitHubValidatedRepositoryKey(repositoryLabel: context.repositoryLabel, branch: context.branch)] = repository
        }

        func validatedRepository(for context: GitHubChatContext) -> GitHubIndexedRepository? {
            validatedRepositories[GitHubValidatedRepositoryKey(repositoryLabel: context.repositoryLabel, branch: context.branch)]
        }

        mutating func invalidateValidatedRepositories(for context: GitHubChatContext) {
            validatedRepositories.removeValue(forKey: GitHubValidatedRepositoryKey(repositoryLabel: context.repositoryLabel, branch: context.branch))
        }

        mutating func finishRoundIfNeeded(logger: Logger) {
            guard currentRoundUsedGitHubTool else {
                return
            }

            if currentRoundMadeProgress {
                consecutiveNoProgressGitHubRounds = 0
            } else {
                consecutiveNoProgressGitHubRounds += 1
            }

            guard hasSuccessfulGitHubResult, !answerFromEvidenceMode else {
                return
            }

            if promptIntent.prefersAnswerAfterSufficientEvidence && meetsSynthesisEvidenceThreshold {
                answerFromEvidenceMode = true
                blockedSynthesisToolCallCount = 0
                requiresTentativeSynthesis =
                    promptIntent.requiresGroundedStateOwnershipAnswer &&
                    !meetsGroundingThreshold
                let roundNumber = currentRoundNumber
                let tentativeSynthesis = requiresTentativeSynthesis
                let paths = synthesisSuggestedPaths.joined(separator: ", ")
                logger.notice("Entering GitHub answer-from-evidence mode in round \(roundNumber, privacy: .public) reason=evidence_sufficient tentative=\(tentativeSynthesis, privacy: .public) evidencePaths=\(paths, privacy: .public)")
                return
            }

            let maxSearchAdvisoryCount = Dictionary(grouping: searchObservations, by: { $0.key.normalizedQuery })
                .values
                .map { observations in observations.map(\.value.advisoryCount).max() ?? 0 }
                .max() ?? 0

            if consecutiveNoProgressGitHubRounds >= 2 || maxSearchAdvisoryCount >= 2 {
                answerFromEvidenceMode = true
                blockedSynthesisToolCallCount = 0
                requiresTentativeSynthesis =
                    promptIntent.requiresGroundedStateOwnershipAnswer &&
                    !meetsGroundingThreshold
                let roundNumber = currentRoundNumber
                let noProgressRounds = consecutiveNoProgressGitHubRounds
                let tentativeSynthesis = requiresTentativeSynthesis
                let paths = synthesisSuggestedPaths.joined(separator: ", ")
                logger.notice("Entering GitHub answer-from-evidence mode in round \(roundNumber, privacy: .public) consecutiveNoProgress=\(noProgressRounds, privacy: .public) maxSearchAdvisoryCount=\(maxSearchAdvisoryCount, privacy: .public) tentative=\(tentativeSynthesis, privacy: .public) evidencePaths=\(paths, privacy: .public)")
            }
        }

        var meetsSynthesisEvidenceThreshold: Bool {
            if confirmedSourcePaths.count >= 2 {
                return true
            }
            if confirmedSourcePaths.count >= 1 && inferredSourcePaths.count >= 2 {
                return true
            }
            return false
        }

        var meetsGroundingThreshold: Bool {
            if !promptIntent.requiresGroundedStateOwnershipAnswer {
                return true
            }
            return meetsSynthesisEvidenceThreshold
        }

        var synthesisSuggestedPaths: [String] {
            Array((sortedConfirmedSourcePaths + sortedInferredSourcePaths + sortedSupportEvidencePaths).prefix(8))
        }

        var sortedEvidencePaths: [String] {
            synthesisSuggestedPaths
        }

        var sortedConfirmedSourcePaths: [String] {
            confirmedSourcePaths.sorted()
        }

        var sortedInferredSourcePaths: [String] {
            inferredSourcePaths.subtracting(confirmedSourcePaths).sorted()
        }

        var sortedSupportEvidencePaths: [String] {
            supportEvidencePaths
                .subtracting(confirmedSourcePaths)
                .subtracting(inferredSourcePaths)
                .sorted()
        }

        private mutating func classifyEvidence(_ newPaths: [String], source: GitHubEvidenceSource) {
            evidencePaths.formUnion(newPaths)

            if subsystemAnchorTokens.isEmpty {
                if let anchorPath = newPaths.first(where: { Self.isLikelyProductionSourcePath($0) }) {
                    let anchorTokens = Self.subsystemTokens(for: anchorPath)
                    if !anchorTokens.isEmpty {
                    subsystemAnchorTokens = anchorTokens
                    }
                }
            }

            for path in newPaths {
                guard Self.isLikelyProductionSourcePath(path) else {
                    supportEvidencePaths.insert(path)
                    continue
                }

                let isCompatibleWithAnchor = subsystemAnchorTokens.isEmpty || !Self.subsystemTokens(for: path).isDisjoint(with: subsystemAnchorTokens)
                if !isCompatibleWithAnchor {
                    supportEvidencePaths.insert(path)
                    continue
                }

                switch source {
                case .readBacked:
                    confirmedSourcePaths.insert(path)
                    inferredSourcePaths.remove(path)

                case .searchBacked:
                    if !confirmedSourcePaths.contains(path) {
                        inferredSourcePaths.insert(path)
                    }

                case .miscellaneous:
                    supportEvidencePaths.insert(path)
                }
            }
        }

        private static func isLikelyProductionSourcePath(_ path: String) -> Bool {
            let lowercasedPath = path.lowercased()
            guard lowercasedPath.hasSuffix(".swift") ||
                    lowercasedPath.hasSuffix(".m") ||
                    lowercasedPath.hasSuffix(".mm") ||
                    lowercasedPath.hasSuffix(".h") ||
                    lowercasedPath.hasSuffix(".hpp") ||
                    lowercasedPath.hasSuffix(".c") ||
                    lowercasedPath.hasSuffix(".cc") ||
                    lowercasedPath.hasSuffix(".cpp") ||
                    lowercasedPath.hasSuffix(".kt") ||
                    lowercasedPath.hasSuffix(".java") ||
                    lowercasedPath.hasSuffix(".go") ||
                    lowercasedPath.hasSuffix(".rs") ||
                    lowercasedPath.hasSuffix(".js") ||
                    lowercasedPath.hasSuffix(".ts") ||
                    lowercasedPath.hasSuffix(".tsx") ||
                    lowercasedPath.hasSuffix(".jsx")
            else {
                return false
            }

            guard !lowercasedPath.contains("/tests/"),
                  !lowercasedPath.hasSuffix("tests.swift"),
                  !lowercasedPath.contains("/docs/"),
                  !lowercasedPath.hasSuffix(".md"),
                  !lowercasedPath.contains(".xcassets/"),
                  !lowercasedPath.contains(".xcodeproj/"),
                  !lowercasedPath.contains("/xcuserdata/"),
                  !lowercasedPath.hasSuffix(".pbxproj"),
                  !lowercasedPath.hasSuffix("protocol.swift")
            else {
                return false
            }

            return true
        }

        private static func subsystemTokens(for path: String) -> Set<String> {
            let stopwords: Set<String> = [
                "porch", "services", "service", "connectors", "connector", "view", "views",
                "viewmodel", "viewmodels", "model", "models", "utilities", "utility", "shared",
                "chat", "settings", "tests", "test", "docs", "doc", "sources", "source",
                "swift", "state", "context", "selection", "session", "store", "stores",
                "cache", "index", "api", "client", "sheet", "protocol"
            ]
            let tokens = Set(GitHubSearchNormalizer.tokenize(path))
            return tokens.subtracting(stopwords)
        }
    }

    private struct GitHubRepoTreeQueryKey: Hashable {
        var branch: String
        var pathPrefix: String?
        var entryType: String
        var maxEntries: Int

        var normalizedPathPrefixForLoopTracking: String {
            (pathPrefix ?? "/").lowercased()
        }
    }

    private struct GitHubRepoTreeObservation {
        var wasEmpty: Bool
    }

    private struct GitHubFileReadKey: Hashable {
        var branch: String
        var path: String
    }

    private struct GitHubFileReadState {
        var wasTruncated: Bool
    }

    private struct GitHubSearchQueryKey: Hashable {
        var branch: String
        var tool: String
        var normalizedQuery: String
    }

    private struct GitHubSearchObservation {
        var resultSignature: String
        var noProgressRepeatCount: Int
        var topPaths: [String]
        var advisoryCount: Int
        var lastProgressRound: Int
        var executionCount: Int
    }

    private struct GitHubToolAdvisoryResult: Encodable {
        var status: String = "redundant_call"
        var tool: String
        var reason: String
        var path: String?
        var path_prefix: String?
        var suggested_next_step: String
        var suggested_paths: [String]?
    }

    private struct GitHubValidatedRepositoryKey: Hashable {
        var repositoryLabel: String
        var branch: String
    }
}
