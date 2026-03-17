import Combine
import SwiftData
import SwiftUI

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable private var chat: ChatThread
    @Query private var messages: [ChatMessage]
    @StateObject private var viewModel: ChatViewModel
    @State private var scrollPosition = ScrollPosition(idType: MessageBubbleID.self)
    @State private var isNearBottom = true

    init(chat: ChatThread, settings: AppSettings, modelContext: ModelContext) {
        let chatID = chat.id
        self._chat = Bindable(chat)
        self._messages = Query(
            filter: #Predicate<ChatMessage> { message in
                message.thread?.id == chatID
            },
            sort: [SortDescriptor(\ChatMessage.createdAt, order: .forward)]
        )
        self._viewModel = StateObject(
            wrappedValue: ChatViewModel(
                chat: chat,
                settings: settings,
                modelContext: modelContext
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let infoMessage = viewModel.infoMessage {
                ErrorBanner(message: infoMessage, color: .blue, onDismiss: viewModel.clearInfo)
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage, color: .red, onDismiss: viewModel.clearError)
            }

            Divider()
            InputBar(
                text: $viewModel.composerText,
                isStreaming: viewModel.isStreaming,
                onSend: viewModel.sendCurrentInput,
                onStop: viewModel.stopGenerating
            )
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var persistedBubbleModels: [MessageBubbleModel] {
        let lastPersistedMessageID = messages.last?.id
        return messages.map { message in
            MessageBubbleModel(
                message: message,
                isRegenerateEnabled: !viewModel.isStreaming
                    && message.role == .assistant
                    && message.id == lastPersistedMessageID
            )
        }
    }

    private var lastPersistedBubbleID: MessageBubbleID? {
        messages.last.map { .persisted($0.id) }
    }

    private var bottomScrollTarget: MessageBubbleID? {
        if streamingBubbleModel != nil {
            return .streaming
        }

        return lastPersistedBubbleID
    }

    private var streamingBubbleModel: MessageBubbleModel? {
        guard viewModel.isStreaming, !viewModel.streamingText.isEmpty else {
            return nil
        }

        return MessageBubbleModel(
            id: .streaming,
            role: .assistant,
            content: viewModel.streamingText,
            isPartial: false,
            finishReason: nil,
            isStreaming: true,
            isRegenerateEnabled: false
        )
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(persistedBubbleModels) { bubble in
                    MessageBubble(
                        model: bubble,
                        onRegenerate: viewModel.regenerateLastResponse
                    )
                    .equatable()
                    .id(bubble.id)
                }

                if let streamingBubbleModel {
                    MessageBubble(
                        model: streamingBubbleModel,
                        onRegenerate: {}
                    )
                    .id(MessageBubbleID.streaming)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self, of: { geometry in
            let bottomContentEdge = geometry.contentSize.height + geometry.contentInsets.bottom
            let distanceFromBottom = bottomContentEdge - geometry.visibleRect.maxY
            return distanceFromBottom < 120
        }) { _, isNear in
            isNearBottom = isNear
        }
        .onReceive(
            viewModel.$streamingText
                .removeDuplicates()
                .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
        ) { _ in
            guard isNearBottom else { return }
            scrollToBottom()
        }
        .onChange(of: messages.count) { _, _ in
            guard isNearBottom else { return }
            scrollToBottom(animation: .easeOut(duration: 0.12))
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                Button {
                    scrollToBottom(animation: .spring(duration: 0.2))
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white, .blue)
                        .shadow(radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private func scrollToBottom(animation: Animation? = nil) {
        guard let target = bottomScrollTarget else { return }
        if let animation {
            withAnimation(animation) {
                scrollPosition.scrollTo(id: target, anchor: .bottom)
            }
        } else {
            scrollPosition.scrollTo(id: target, anchor: .bottom)
        }
    }
}
