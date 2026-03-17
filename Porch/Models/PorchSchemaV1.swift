import Foundation
import SwiftData

enum PorchSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        .init(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            AppSettings.self,
            ChatThread.self,
            ChatMessage.self
        ]
    }

    @Model
    final class AppSettings {
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

        init() {
            self.recordID = "app-settings"
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
    }

    @Model
    final class ChatThread {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var serverBaseURL: String
        var modelID: String
        var systemPrompt: String

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
            self.serverBaseURL = serverBaseURL
            self.modelID = modelID
            self.systemPrompt = systemPrompt
            self.messages = []
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

        var thread: ChatThread?

        init(
            role: MessageRole,
            content: String,
            thread: ChatThread? = nil,
            isPartial: Bool = false,
            finishReason: ChatFinishReason? = nil,
            createdAt: Date = .now
        ) {
            self.id = UUID()
            self.roleRaw = role.rawValue
            self.content = content
            self.createdAt = createdAt
            self.isPartial = isPartial
            self.finishReasonRaw = finishReason?.apiValue
            self.thread = thread
        }
    }
}
