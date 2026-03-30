import Combine
import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    private static let streamingPublishInterval = Duration.milliseconds(50)
    private static let maxToolCallRounds = 25
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
    private var gitHubToolLoopState = GitHubToolLoopState()

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
        gitHubToolLoopState.reset()

        do {
            let configuration = try currentServerConfiguration()

            streamTask = Task {
                await runToolCallingLoop(configuration: configuration, parameters: parameters)
                isStreaming = false
                stopRequested = false
                streamTask = nil
            }
        } catch {
            isStreaming = false
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

            do {
                let outboundMessages = try buildOutboundMessages()
                let tools = resolveToolDefinitions()
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
                    Self.logger.notice("Tool loop completed without more tool calls in round \(roundNumber). finishReason=\(String(describing: finishReason))")
                    infoMessage = finishReason?.userMessage
                    return

                case .toolCallsReceived(let toolCalls, let assistantContent):
                    let toolNames = toolCalls.map(\.function.name).joined(separator: ", ")
                    Self.logger.notice("Tool loop round \(roundNumber) received \(toolCalls.count) tool call(s): \(toolNames)")
                    if let assistantContent, !assistantContent.isEmpty {
                        Self.logger.debug("Assistant included \(assistantContent.count) characters alongside tool calls in round \(roundNumber)")
                    }
                    // Persist the assistant message that requested tool calls
                    persistAssistantToolCallMessage(content: assistantContent, toolCalls: toolCalls)

                    // Execute each tool call and persist results
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

                    // Refresh memory context if a memory was saved this round
                    if settings.isMemoryConnectorEnabled,
                       let memoryConnector,
                       toolCalls.contains(where: { $0.function.name == "save_memory" }) {
                        cachedMemorySnippet = await memoryConnector.memoryContextSnippet()
                    }
                    // Continue the loop for another round

                case .cancelled:
                    Self.logger.notice("Tool loop cancelled in round \(roundNumber)")
                    return

                case .error(let error):
                    Self.logger.error("Tool loop failed in round \(roundNumber): \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                    return
                }
            } catch {
                Self.logger.error("Failed to build or run tool loop round \(roundNumber): \(error.localizedDescription)")
                streamingText = ""
                streamingThinkingText = ""
                isModelThinking = false
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
                persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
                return .cancelled
            }

            let roundDuration = clock.now - roundStartTime

            // If we received tool calls, return them for the loop to handle
            if let toolCalls = receivedToolCalls, !toolCalls.isEmpty {
                Self.logger.notice("Stream round completed in \(roundDuration) with \(toolCalls.count) native tool call(s), responseLength=\(draftText.count)")
                let content = draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftText
                streamingText = ""
                return .toolCallsReceived(toolCalls, assistantContent: content)
            }

            // Normal text completion
            Self.logger.notice("Stream round completed in \(roundDuration) with text, responseLength=\(draftText.count) finishReason=\(String(describing: finishReason))")
            persistAssistantDraft(text: draftText, isPartial: false, finishReason: finishReason, usage: roundUsage)
            return .textCompleted(finishReason)

        } catch is CancellationError {
            let roundDuration = clock.now - roundStartTime
            Self.logger.notice("Stream round cancelled after \(roundDuration), draftLength=\(draftText.count)")
            flushStreamingDraft(draftText)
            persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
            return .cancelled
        } catch {
            let roundDuration = clock.now - roundStartTime
            Self.logger.error("Stream round failed after \(roundDuration): \(error.localizedDescription) draftLength=\(draftText.count)")
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

    private func resolveToolDefinitions() -> [ToolDefinition]? {
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
            tools.append(contentsOf: githubConnector.toolDefinitions(for: githubContext))
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

    private func executeToolCall(_ toolCall: ToolCall) async -> String? {
        let execStart = ContinuousClock.now
        Self.logger.notice("Executing tool \(toolCall.function.name) callId=\(toolCall.id) args=\(toolCall.function.arguments.prefix(500))")

        if logStoreConnector.toolDefinitions.contains(where: { $0.function.name == toolCall.function.name }) {
            do {
                let result = try await logStoreConnector.execute(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                Self.logger.notice("Tool \(toolCall.function.name) completed in \(ContinuousClock.now - execStart) resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("Tool \(toolCall.function.name) failed in \(ContinuousClock.now - execStart): \(error.localizedDescription)")
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
                Self.logger.notice("Tool \(toolCall.function.name) completed in \(ContinuousClock.now - execStart) resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("Tool \(toolCall.function.name) failed in \(ContinuousClock.now - execStart): \(error.localizedDescription)")
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
                    Self.logger.notice("MCP tool \(toolCall.function.name) completed in \(ContinuousClock.now - execStart) resultLength=\(result.count)")
                    return result
                } catch {
                    Self.logger.error("MCP tool \(toolCall.function.name) failed in \(ContinuousClock.now - execStart): \(error.localizedDescription)")
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
                Self.logger.notice("Tool \(toolCall.function.name) completed in \(ContinuousClock.now - execStart) resultLength=\(result.count)")
                return result
            } catch {
                Self.logger.error("Tool \(toolCall.function.name) failed in \(ContinuousClock.now - execStart): \(error.localizedDescription)")
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

            Self.logger.notice("Executing GitHub tool \(toolCall.function.name) for \(githubContext.repositoryLabel) on branch \(githubContext.branch)")

            if let advisoryResult = suppressRedundantGitHubToolCallIfNeeded(toolCall, context: githubContext) {
                return advisoryResult
            }

            if githubConnector.isWriteTool(toolCall.function.name) {
                let request = try await githubConnector.prepareWriteRequest(
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments,
                    context: githubContext
                )
                Self.logger.notice("Prepared GitHub write request for \(request.repositoryFullName) base=\(request.resolvedBaseRef) proposedBranch=\(request.proposedBranchName) changeCount=\(request.changes.count)")
                switch await waitForGitHubWriteApproval(request: request) {
                case .approve(let branchName, let commitMessage):
                    Self.logger.notice("User approved GitHub write for \(request.repositoryFullName) branch=\(branchName) commitLength=\(commitMessage.count)")
                    streamingText = "Creating GitHub branch and pushing changes..."
                    let result = try await githubConnector.executeApprovedWrite(
                        request,
                        branchName: branchName,
                        commitMessage: commitMessage
                    )
                    Self.logger.notice("GitHub write completed for \(request.repositoryFullName) branch=\(result.branch_name) commit=\(result.commit_sha)")
                    return try encodeToolResult(result)

                case .cancelByUser:
                    Self.logger.notice("User cancelled GitHub write approval for \(request.repositoryFullName)")
                    streamingText = ""
                    return try encodeToolResult(
                        GitHubWriteCancelledResult(reason: "User declined GitHub write approval.")
                    )

                case .stopGeneration:
                    Self.logger.notice("GitHub write approval dismissed because generation was stopped for \(request.repositoryFullName)")
                    streamingText = ""
                    return nil
                }
            }

            let result = try await githubConnector.execute(
                toolName: toolCall.function.name,
                arguments: toolCall.function.arguments,
                context: githubContext
            )
            recordGitHubToolResultIfNeeded(
                toolName: toolCall.function.name,
                arguments: toolCall.function.arguments,
                result: result,
                context: githubContext
            )
            Self.logger.notice("Tool \(toolCall.function.name) completed in \(ContinuousClock.now - execStart) resultLength=\(result.count)")
            return result
        } catch {
            Self.logger.error("Tool \(toolCall.function.name) failed in \(ContinuousClock.now - execStart): \(error.localizedDescription)")
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
            toolCallResultJSON: result
        )
        modelContext.insert(toolMessage)
        chat.applyMessageMutation(latestMessage: toolMessage)
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Save failed in persistToolResultMessage for \(toolCall.function.name): \(error.localizedDescription)")
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

    private func buildOutboundMessages() throws -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
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

        if settings.isGitHubConnectorEnabled,
           githubConnector.isConfigured,
           let ctx = chat.githubContext {
            messages.append(OpenAIChatMessage(
                role: MessageRole.system.rawValue,
                content: gitHubPromptGuidance(for: ctx)
            ))
        }

        let persistedMessages = try ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        let latestFileReadToolMessageIDs = latestGitHubFileReadToolMessageIDs(in: persistedMessages)
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
                if message.toolCallName == "github_get_file_content",
                   !latestFileReadToolMessageIDs.contains(message.id) {
                    continue
                }
                let msg = OpenAIChatMessage(
                    role: message.role.rawValue,
                    content: message.toolCallResultJSON ?? message.content,
                    toolCallID: message.toolCallID ?? "",
                    name: message.toolCallName ?? ""
                )
                messages.append(msg)

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
        Self.logger.notice("Outbound messages: \(messages.count) total (system=\(systemMsgCount) user=\(userMsgCount) assistant=\(assistantMsgCount) tool=\(toolMsgCount)) totalChars=\(totalChars)")
        return messages
    }

    private func gitHubPromptGuidance(for context: GitHubChatContext) -> String {
        """
        GitHub context: \(context.owner)/\(context.repo) on branch \(context.branch). \
        Use github_get_repo_tree once to discover candidate paths, then reuse that earlier tree result instead of rescanning the same subtree. \
        Avoid rereading the same file path unless the earlier github_get_file_content result was truncated=true. \
        Use github_get_file_content before updating an existing file, and switch to github_get_file_tail for large files or edits near the end of a file. \
        Batch multi-file edits into one github_commit_file_changes call by putting all requested file updates inside changes[].
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
        context: GitHubChatContext
    ) -> String? {
        switch toolCall.function.name {
        case "github_get_repo_tree":
            guard let queryKey = gitHubRepoTreeQueryKey(
                from: toolCall.function.arguments,
                branch: context.branch
            ) else {
                return nil
            }
            guard gitHubToolLoopState.successfulRepoTreeQueries.contains(queryKey) else {
                return nil
            }

            let advisory = GitHubToolAdvisoryResult(
                tool: toolCall.function.name,
                reason: "This repository tree query already succeeded earlier in this run.",
                path_prefix: queryKey.pathPrefix,
                suggested_next_step: "Reuse the earlier github_get_repo_tree result already in context, then continue with github_get_file_content, github_get_file_tail, or github_commit_file_changes."
            )
            Self.logger.notice("Suppressing redundant GitHub repo tree call for \(context.repositoryLabel) branch=\(context.branch) prefix=\(queryKey.pathPrefix ?? "/")")
            return try? encodeToolResult(advisory)

        case "github_get_file_content":
            guard let readKey = gitHubFileReadKey(
                from: toolCall.function.arguments,
                branch: context.branch
            ),
            let priorRead = gitHubToolLoopState.successfulFileReads[readKey] else {
                return nil
            }

            let suggestedNextStep: String
            let reason: String
            if priorRead.wasTruncated {
                reason = "This file was already read earlier in this run, and the earlier full-file result was truncated."
                suggestedNextStep = "Use github_get_file_tail for this path to inspect the end of the file before appending or editing near the bottom."
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
            gitHubToolLoopState.successfulRepoTreeQueries.insert(queryKey)

        case "github_get_file_content":
            guard let path = payload["path"] as? String else {
                return
            }
            let readKey = GitHubFileReadKey(branch: context.branch, path: path)
            let wasTruncated = gitHubToolResultTruncated(payload)
            gitHubToolLoopState.successfulFileReads[readKey] = GitHubFileReadState(wasTruncated: wasTruncated)

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

        let maxEntries = payload["max_entries"] as? Int ?? 400
        guard maxEntries > 0, maxEntries <= 1_000 else {
            return nil
        }

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
            "github_get_repo_tree": "GitHub Repo Tree",
            "github_get_repo_contents": "GitHub Browse Files",
            "github_get_file_content": "GitHub Read File",
            "github_get_file_tail": "GitHub Read File Tail",
            "github_list_issues": "GitHub Issues",
            "github_get_issue": "GitHub Issue",
            "github_list_pull_requests": "GitHub Pull Requests",
            "github_get_pull_request": "GitHub Pull Request",
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

    private enum GitHubWriteApprovalDecision {
        case approve(branchName: String, commitMessage: String)
        case cancelByUser
        case stopGeneration
    }

    private struct GitHubToolLoopState {
        var successfulRepoTreeQueries: Set<GitHubRepoTreeQueryKey> = []
        var successfulFileReads: [GitHubFileReadKey: GitHubFileReadState] = [:]

        mutating func reset() {
            successfulRepoTreeQueries.removeAll(keepingCapacity: false)
            successfulFileReads.removeAll(keepingCapacity: false)
        }
    }

    private struct GitHubRepoTreeQueryKey: Hashable {
        var branch: String
        var pathPrefix: String?
        var entryType: String
        var maxEntries: Int
    }

    private struct GitHubFileReadKey: Hashable {
        var branch: String
        var path: String
    }

    private struct GitHubFileReadState {
        var wasTruncated: Bool
    }

    private struct GitHubToolAdvisoryResult: Encodable {
        var status: String = "redundant_call"
        var tool: String
        var reason: String
        var path: String?
        var path_prefix: String?
        var suggested_next_step: String
    }
}
