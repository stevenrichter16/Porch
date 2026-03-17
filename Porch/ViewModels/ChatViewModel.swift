import Combine
import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    private static let streamingPublishInterval = Duration.milliseconds(50)

    @Published var composerText = ""
    @Published var streamingText = ""
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let chat: ChatThread
    private let settings: AppSettings
    private let modelContext: ModelContext
    private let client: OpenAICompatibleClient
    private let keychain: KeychainStoreProtocol
    private let apiKeyAccount = "active-server-api-key"

    private var streamTask: Task<Void, Never>?
    private var stopRequested = false

    init(
        chat: ChatThread,
        settings: AppSettings,
        modelContext: ModelContext,
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keychain: KeychainStoreProtocol = KeychainStore()
    ) {
        self.chat = chat
        self.settings = settings
        self.modelContext = modelContext
        self.client = client
        self.keychain = keychain
    }

    deinit {
        streamTask?.cancel()
    }

    func sendCurrentInput() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = ""
        send(messageText: trimmed)
    }

    func stopGenerating() {
        stopRequested = true
        streamTask?.cancel()
    }

    func regenerateLastResponse() {
        let persistedMessages = try? ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        guard let messages = persistedMessages, let lastMessage = messages.last, lastMessage.role == .assistant else {
            return
        }

        modelContext.delete(lastMessage)
        let previousLatestMessage = messages.dropLast().last
        chat.applyMessageMutation(latestMessage: previousLatestMessage)
        try? modelContext.save()
        startStreamingConversation()
    }

    func clearError() {
        errorMessage = nil
    }

    func clearInfo() {
        infoMessage = nil
    }

    private func send(messageText: String) {
        let userMessage = ChatMessage(role: .user, content: messageText, thread: chat)
        modelContext.insert(userMessage)
        if chat.isUntitled {
            chat.title = ChatTitleGenerator.title(for: messageText)
        }
        chat.applyMessageMutation(latestMessage: userMessage)
        try? modelContext.save()
        startStreamingConversation()
    }

    private func startStreamingConversation() {
        streamTask?.cancel()
        errorMessage = nil
        infoMessage = nil
        streamingText = ""
        isStreaming = true
        stopRequested = false

        do {
            let configuration = try currentServerConfiguration()
            let outboundMessages = try buildOutboundMessages()
            let descriptor = OpenAIChatRequestDescriptor(
                configuration: configuration,
                modelID: chat.modelID,
                messages: outboundMessages,
                parameters: settings.generationParameters
            )

            streamTask = Task {
                var finishReason: ChatFinishReason?
                var draftText = ""
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
                        case .completed(let reason):
                            finishReason = reason
                        }
                    }

                    flushStreamingDraft(draftText)
                    if stopRequested {
                        persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
                    } else {
                        persistAssistantDraft(text: draftText, isPartial: false, finishReason: finishReason)
                        infoMessage = finishReason?.userMessage
                    }
                } catch is CancellationError {
                    flushStreamingDraft(draftText)
                    persistAssistantDraft(text: draftText, isPartial: true, finishReason: .cancelled)
                } catch {
                    flushStreamingDraft(draftText)
                    let hadDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hadDraft {
                        let persistedReason: ChatFinishReason? = stopRequested ? .cancelled : finishReason
                        persistAssistantDraft(text: draftText, isPartial: true, finishReason: persistedReason)
                    }
                    if !stopRequested {
                        errorMessage = error.localizedDescription
                    }
                }

                isStreaming = false
                stopRequested = false
                streamTask = nil
            }
        } catch {
            isStreaming = false
            errorMessage = error.localizedDescription
        }
    }

    private func currentServerConfiguration() throws -> ServerConfiguration {
        ServerConfiguration(
            baseURL: chat.serverBaseURL,
            apiKey: try keychain.read(account: apiKeyAccount)
        )
    }

    private func buildOutboundMessages() throws -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
        if !chat.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(OpenAIChatMessage(role: MessageRole.system.rawValue, content: chat.systemPrompt))
        }

        let persistedMessages = try ChatMessageQueries.fetchSortedMessages(for: chat, in: modelContext)
        for message in persistedMessages {
            messages.append(
                OpenAIChatMessage(
                    role: message.role.rawValue,
                    content: message.content
                )
            )
        }

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
            streamingText = ""
            return
        }

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
}
