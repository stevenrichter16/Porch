import Foundation
import SwiftData

enum PorchSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        .init(7, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            AppSettings.self,
            ChatThread.self,
            ChatMessage.self,
            MemoryEntry.self
        ]
    }

    @Model
    final class AppSettings {
        static let singletonID = "app-settings"
        private static let modelsDecoder = JSONDecoder()
        private static let modelsEncoder = JSONEncoder()

        @Attribute(.unique) var recordID: String
        var activeBaseURL: String
        var defaultModelID: String
        var defaultSystemPrompt: String
        var temperature: Double
        var maxTokens: Int
        var topP: Double
        var frequencyPenalty: Double
        var presencePenalty: Double
        var stopSequencesRaw: String
        var availableModelsData: Data?
        var validationStateRaw: String
        var lastValidationMessage: String
        var lastValidatedAt: Date?
        var updatedAt: Date
        var isGitHubConnectorEnabled: Bool = false
        var isWebSearchConnectorEnabled: Bool = false
        var toolCallingModeRaw: String = ToolCallingMode.auto.rawValue
        var isMemoryConnectorEnabled: Bool = true
        var mcpServerConfigsData: Data?

        init() {
            self.recordID = Self.singletonID
            self.activeBaseURL = ""
            self.defaultModelID = ""
            self.defaultSystemPrompt = ""
            self.temperature = GenerationParameters.default.temperature
            self.maxTokens = GenerationParameters.default.maxTokens
            self.topP = GenerationParameters.default.topP
            self.frequencyPenalty = GenerationParameters.default.frequencyPenalty
            self.presencePenalty = GenerationParameters.default.presencePenalty
            self.stopSequencesRaw = ""
            self.availableModelsData = nil
            self.validationStateRaw = ConnectionValidationState.notValidated.rawValue
            self.lastValidationMessage = ""
            self.lastValidatedAt = nil
            self.updatedAt = .now
        }

        var validationState: ConnectionValidationState {
            get { ConnectionValidationState(rawValue: validationStateRaw) ?? .notValidated }
            set { validationStateRaw = newValue.rawValue }
        }

        var toolCallingMode: ToolCallingMode {
            get { ToolCallingMode(rawValue: toolCallingModeRaw) ?? .auto }
            set { toolCallingModeRaw = newValue.rawValue }
        }

        var generationParameters: GenerationParameters {
            get {
                GenerationParameters(
                    temperature: temperature,
                    maxTokens: maxTokens,
                    topP: topP,
                    frequencyPenalty: frequencyPenalty,
                    presencePenalty: presencePenalty,
                    stopSequences: stopSequencesRaw
                        .split(separator: "\n")
                        .map { String($0) }
                        .filter { !$0.isEmpty }
                )
            }
            set {
                temperature = newValue.temperature
                maxTokens = newValue.maxTokens
                topP = newValue.topP
                frequencyPenalty = newValue.frequencyPenalty
                presencePenalty = newValue.presencePenalty
                stopSequencesRaw = newValue.stopSequences.joined(separator: "\n")
            }
        }

        var availableModels: [RemoteModel] {
            get {
                guard let availableModelsData else {
                    return []
                }

                return (try? Self.modelsDecoder.decode([RemoteModel].self, from: availableModelsData)) ?? []
            }
            set {
                availableModelsData = try? Self.modelsEncoder.encode(newValue)
            }
        }

        var isReadyForChat: Bool {
            validationState == .valid &&
            !activeBaseURL.isEmpty &&
            !defaultModelID.isEmpty &&
            !availableModels.isEmpty
        }

        func markUpdated() {
            updatedAt = .now
        }
    }

    @Model
    final class ChatThread {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        @Attribute(originalName: "lastMessagePreview") var lastMessagePreviewStorage: String?
        var serverBaseURL: String
        var modelID: String
        var systemPrompt: String
        var githubRepoOwner: String?
        var githubRepoName: String?
        var githubRepoFullName: String?
        var githubBranchName: String?

        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
        var messages: [ChatMessage]

        init(
            title: String = "New Chat",
            serverBaseURL: String,
            modelID: String,
            systemPrompt: String
        ) {
            self.id = UUID()
            self.title = title
            self.createdAt = .now
            self.updatedAt = .now
            self.lastMessagePreviewStorage = nil
            self.serverBaseURL = serverBaseURL
            self.modelID = modelID
            self.systemPrompt = systemPrompt
            self.githubRepoOwner = nil
            self.githubRepoName = nil
            self.githubRepoFullName = nil
            self.githubBranchName = nil
            self.messages = []
        }

        var lastMessagePreview: String {
            get { lastMessagePreviewStorage ?? "" }
            set {
                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                lastMessagePreviewStorage = normalized.isEmpty ? nil : newValue
            }
        }

        var sortedMessages: [ChatMessage] {
            messages.sorted { $0.createdAt < $1.createdAt }
        }

        var isUntitled: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "New Chat"
        }

        var githubContext: GitHubChatContext? {
            guard
                let githubRepoOwner,
                let githubRepoName,
                let githubRepoFullName,
                let githubBranchName
            else {
                return nil
            }

            return GitHubChatContext(
                owner: githubRepoOwner,
                repo: githubRepoName,
                fullName: githubRepoFullName,
                branch: githubBranchName
            )
        }

        func markUpdated() {
            updatedAt = .now
        }

        func applyMessageMutation(latestMessage: ChatMessage?) {
            lastMessagePreview = latestMessage?.previewText ?? ""
            markUpdated()
        }

        @discardableResult
        func backfillLastMessagePreview(from latestMessage: ChatMessage?) -> Bool {
            guard lastMessagePreview.isEmpty else {
                return false
            }

            lastMessagePreview = latestMessage?.previewText ?? ""
            return !lastMessagePreview.isEmpty
        }

        func applyGitHubContext(_ context: GitHubChatContext?) {
            githubRepoOwner = context?.owner
            githubRepoName = context?.repo
            githubRepoFullName = context?.fullName
            githubBranchName = context?.branch
            markUpdated()
        }
    }

    @Model
    final class ChatMessage {
        var id: UUID
        var roleRaw: String
        var content: String
        var createdAt: Date
        var isPartial: Bool
        var finishReasonRaw: String?
        var toolCallID: String?
        var toolCallName: String?
        var toolCallArgumentsJSON: String?
        var toolCallResultJSON: String?
        // V7: Thinking/reasoning content extracted from <think> tags
        var thinkingContent: String?
        // V7: Token usage tracking
        var promptTokens: Int?
        var completionTokens: Int?
        // V7: Conversation branching
        var parentMessageID: UUID?
        var branchIndex: Int = 0
        var activeBranchMessageID: UUID?
        // V7: Image attachment
        var imageData: Data?
        var imageMimeType: String?

        var thread: ChatThread?

        init(
            role: MessageRole,
            content: String,
            thread: ChatThread? = nil,
            isPartial: Bool = false,
            finishReason: ChatFinishReason? = nil,
            createdAt: Date = .now,
            toolCallID: String? = nil,
            toolCallName: String? = nil,
            toolCallArgumentsJSON: String? = nil,
            toolCallResultJSON: String? = nil,
            thinkingContent: String? = nil,
            promptTokens: Int? = nil,
            completionTokens: Int? = nil,
            parentMessageID: UUID? = nil,
            branchIndex: Int = 0,
            imageData: Data? = nil,
            imageMimeType: String? = nil
        ) {
            self.id = UUID()
            self.roleRaw = role.rawValue
            self.content = content
            self.createdAt = createdAt
            self.isPartial = isPartial
            self.finishReasonRaw = finishReason?.apiValue
            self.toolCallID = toolCallID
            self.toolCallName = toolCallName
            self.toolCallArgumentsJSON = toolCallArgumentsJSON
            self.toolCallResultJSON = toolCallResultJSON
            self.thinkingContent = thinkingContent
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.parentMessageID = parentMessageID
            self.branchIndex = branchIndex
            self.activeBranchMessageID = nil
            self.imageData = imageData
            self.imageMimeType = imageMimeType
            self.thread = thread
        }

        var role: MessageRole {
            get { MessageRole(rawValue: roleRaw) ?? .assistant }
            set { roleRaw = newValue.rawValue }
        }

        var finishReason: ChatFinishReason? {
            get {
                guard let finishReasonRaw else { return nil }
                return ChatFinishReason(apiValue: finishReasonRaw)
            }
            set {
                finishReasonRaw = newValue?.apiValue
            }
        }

        var isToolCall: Bool {
            toolCallName != nil && role == .assistant
        }

        var isToolResult: Bool {
            role == .tool
        }

        var totalTokens: Int? {
            guard let promptTokens, let completionTokens else { return nil }
            return promptTokens + completionTokens
        }

        var previewText: String {
            let normalized = content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.count <= 120 {
                return normalized
            }
            return String(normalized.prefix(117)) + "..."
        }
    }

    // MARK: - Memory System

    @Model
    final class MemoryEntry {
        var id: UUID
        var key: String
        var content: String
        var category: String
        var createdAt: Date
        var updatedAt: Date

        init(
            key: String,
            content: String,
            category: String = "general"
        ) {
            self.id = UUID()
            self.key = key
            self.content = content
            self.category = category
            self.createdAt = .now
            self.updatedAt = .now
        }
    }
}
