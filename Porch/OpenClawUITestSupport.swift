import Foundation
import SwiftData

enum OpenClawUITestKeys {
    static let mode = "OPENCLAW_UI_TEST_MODE"
    static let scenario = "OPENCLAW_UI_TEST_SCENARIO"
    static let disableAudio = "OPENCLAW_UI_TEST_DISABLE_AUDIO"
}

struct OpenClawUITestConfiguration {
    let usesInMemoryStore: Bool
    let isDeterministicMode: Bool
    let scenario: String
    let disableAudio: Bool

    static var current: OpenClawUITestConfiguration {
        let isRunningXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let deterministicMode = boolValue(for: OpenClawUITestKeys.mode)
        return OpenClawUITestConfiguration(
            usesInMemoryStore: isRunningXCTest || deterministicMode,
            isDeterministicMode: deterministicMode,
            scenario: stringValue(for: OpenClawUITestKeys.scenario) ?? PorchUITestScenario.onboarding.rawValue,
            disableAudio: boolValue(for: OpenClawUITestKeys.disableAudio)
        )
    }

    private static func boolValue(for key: String) -> Bool {
        guard let rawValue = rawValue(for: key) else {
            return ProcessInfo.processInfo.arguments.contains(key)
        }

        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func stringValue(for key: String) -> String? {
        guard let rawValue = rawValue(for: key) else { return nil }
        return rawValue.isEmpty ? nil : rawValue
    }

    private static func rawValue(for key: String) -> String? {
        let processInfo = ProcessInfo.processInfo

        if let value = processInfo.environment[key], !value.isEmpty {
            return value
        }

        if let argument = processInfo.arguments.first(where: { $0.hasPrefix("\(key)=") }) {
            return String(argument.dropFirst(key.count + 1))
        }

        let userDefaultsValue = UserDefaults.standard.object(forKey: key)
        switch userDefaultsValue {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

enum PorchUITestScenario: String {
    case onboarding = "onboarding"
    case onboardingReadyState = "onboarding_ready_state"
    case createOrSelectChat = "create_or_select_chat"
    case openSettings = "open_settings"

    init(rawScenario: String) {
        self = PorchUITestScenario(rawValue: rawScenario) ?? .onboarding
    }
}

enum PorchAutomationID {
    static let appRoot = "porch.app.root"
    static let loadingRoot = "porch.loading"
    static let chatList = "porch.chat.list"
    static let chatListEmpty = "porch.chat.list.empty"
    static let chatRow = "porch.chat.row"
    static let chatDetailRoot = "porch.chat.detail.root"
    static let chatDetailEmpty = "porch.chat.detail.empty"
    static let settingsRoot = "porch.settings.root"
    static let settingsButton = "porch.chat.settings"
    static let selectionButton = "porch.chat.selection"
    static let newChatButton = "porch.chat.new"
    static let composerField = "porch.chat.input"
    static let sendButton = "porch.chat.send"
    static let promptButton = "porch.chat.prompts"
    static let tuneButton = "porch.chat.tune"
    static let baseURLField = "porch.settings.base-url"
    static let modelPicker = "porch.settings.model-picker"
    static let validateButton = "porch.settings.validate"
}

@MainActor
enum PorchUITestBootstrap {
    static func usesInMemoryStore() -> Bool {
        OpenClawUITestConfiguration.current.usesInMemoryStore
    }

    static func applyIfNeeded(context: ModelContext, settings: AppSettings) {
        let configuration = OpenClawUITestConfiguration.current
        guard configuration.isDeterministicMode else { return }

        resetState(context: context, settings: settings)

        switch PorchUITestScenario(rawScenario: configuration.scenario) {
        case .onboarding:
            break
        case .onboardingReadyState:
            configureReadyState(settings: settings)
        case .createOrSelectChat:
            configureReadyState(settings: settings)
            seedChat(in: context, settings: settings, title: "OpenClaw Seeded Chat", preview: "Ready to review the latest diff?")
        case .openSettings:
            configureReadyState(settings: settings)
        }

        settings.markUpdated()
        try? context.save()
    }

    private static func resetState(context: ModelContext, settings: AppSettings) {
        settings.activeBaseURL = ""
        settings.defaultModelID = ""
        settings.defaultSystemPrompt = ""
        settings.availableModels = []
        settings.validationState = .notValidated
        settings.lastValidationMessage = ""
        settings.lastValidatedAt = nil
        settings.isGitHubConnectorEnabled = false
        settings.isWebSearchConnectorEnabled = false
        settings.toolCallingMode = .auto

        let chats = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
        for chat in chats {
            context.delete(chat)
        }
    }

    private static func configureReadyState(settings: AppSettings) {
        settings.activeBaseURL = "http://127.0.0.1:18793/v1"
        settings.defaultModelID = "openai/gpt-5.2"
        settings.defaultSystemPrompt = "You are Porch running a deterministic OpenClaw UI smoke test."
        settings.availableModels = [
            RemoteModel(id: "openai/gpt-5.2", ownedBy: "openclaw")
        ]
        settings.validationState = .valid
        settings.lastValidationMessage = "Seeded by OpenClaw UI smoke tests."
        settings.lastValidatedAt = .now
    }

    private static func seedChat(in context: ModelContext, settings: AppSettings, title: String, preview: String) {
        let chat = ChatThread(
            title: title,
            serverBaseURL: settings.activeBaseURL,
            modelID: settings.defaultModelID,
            systemPrompt: settings.defaultSystemPrompt
        )
        context.insert(chat)

        let assistantMessage = ChatMessage(role: .assistant, content: preview, thread: chat)
        context.insert(assistantMessage)
        chat.applyMessageMutation(latestMessage: assistantMessage)
    }
}
