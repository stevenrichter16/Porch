import Combine
import Foundation
import SwiftData

@MainActor
final class SettingsViewModel: ObservableObject {
    private static let logger = PorchLogger(category: "Settings")
    @Published var baseURL: String
    @Published var apiKey: String
    @Published var selectedModelID: String
    @Published var availableModels: [RemoteModel]
    @Published var systemPrompt: String
    @Published var parameters: GenerationParameters
    @Published var validationState: ConnectionValidationState
    @Published var validationMessage: String
    @Published var isWorking = false

    private let client: OpenAICompatibleClient
    private let keychain: KeychainStoreProtocol
    private let apiKeyAccount = "active-server-api-key"

    init(
        settings: AppSettings,
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keychain: KeychainStoreProtocol = KeychainStore()
    ) {
        self.client = client
        self.keychain = keychain
        self.baseURL = settings.activeBaseURL
        self.selectedModelID = settings.defaultModelID
        self.availableModels = settings.availableModels
        self.systemPrompt = settings.defaultSystemPrompt
        self.parameters = settings.generationParameters
        self.validationState = settings.validationState
        self.validationMessage = settings.lastValidationMessage
        self.apiKey = (try? keychain.read(account: apiKeyAccount)) ?? ""
    }

    var validationSummary: String {
        if validationMessage.isEmpty {
            return validationState.statusText
        }
        return validationMessage
    }

    func validateAndSave(into settings: AppSettings, modelContext: ModelContext) async -> Bool {
        Self.logger.info("[validate] baseURL=\(baseURL) hasApiKey=\(apiKey.nilIfBlank != nil)")
        isWorking = true
        validationState = .validating
        validationMessage = "Checking server and loading models..."

        defer { isWorking = false }

        do {
            let normalizedURL = try await client.normalizeBaseURL(baseURL)
            let configuration = ServerConfiguration(
                baseURL: normalizedURL.absoluteString,
                apiKey: apiKey.nilIfBlank
            )
            let models = try await client.fetchModels(configuration: configuration)

            availableModels = models
            if !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = models.first?.id ?? ""
            }

            if selectedModelID.isEmpty {
                throw StreamError.missingModels
            }

            let successMessage = "Connected. \(models.count) model\(models.count == 1 ? "" : "s") available."
            try persistValidatedSettings(
                settings: settings,
                using: normalizedURL,
                validationMessage: successMessage,
                modelContext: modelContext
            )
            validationState = .valid
            validationMessage = successMessage
            Self.logger.info("[validate] success modelCount=\(models.count) selectedModel=\(selectedModelID)")
            return true
        } catch {
            Self.logger.error("[validate] error=\(error.localizedDescription)")
            validationState = .invalid
            validationMessage = error.localizedDescription
            return false
        }
    }

    private func persistValidatedSettings(
        settings: AppSettings,
        using normalizedURL: URL,
        validationMessage: String,
        modelContext: ModelContext
    ) throws {
        if let apiKey = apiKey.nilIfBlank {
            try keychain.save(apiKey, account: apiKeyAccount)
        } else {
            try keychain.delete(account: apiKeyAccount)
        }

        settings.activeBaseURL = normalizedURL.absoluteString
        settings.defaultModelID = selectedModelID
        settings.defaultSystemPrompt = systemPrompt
        settings.generationParameters = parameters
        settings.availableModels = availableModels
        settings.validationState = .valid
        settings.lastValidationMessage = validationMessage
        settings.lastValidatedAt = .now
        settings.markUpdated()

        try modelContext.save()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
