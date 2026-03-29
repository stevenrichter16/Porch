import Combine
import SwiftData
import SwiftUI

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable private var chat: ChatThread
    @Bindable private var settings: AppSettings
    @Query private var messages: [ChatMessage]
    @StateObject private var viewModel: ChatViewModel
    @State private var scrollPosition = ScrollPosition(idType: MessageBubbleID.self)
    @State private var isNearBottom = true
    @State private var editingDraft: MessageEditDraft?
    @State private var isShowingGitHubContextSheet = false

    init(chat: ChatThread, settings: AppSettings, modelContext: ModelContext, memoryConnector: MemoryConnector? = nil) {
        let chatID = chat.id
        self._chat = Bindable(chat)
        self._settings = Bindable(settings)
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
                modelContext: modelContext,
                memoryConnector: memoryConnector
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let infoMessage = viewModel.infoMessage {
                ErrorBanner(message: infoMessage, color: PorchTheme.accent, onDismiss: viewModel.clearInfo)
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage, color: PorchTheme.errorBanner, onDismiss: viewModel.clearError)
            }

            PorchTheme.messageDivider
                .frame(height: 0.5)

            InputBar(
                text: $viewModel.composerText,
                globalParameters: viewModel.defaultGenerationParameters,
                nextMessageParameterOverride: Binding(
                    get: { viewModel.nextMessageParameterOverride },
                    set: { viewModel.nextMessageParameterOverride = $0 }
                ),
                isStreaming: viewModel.isStreaming,
                pendingImages: Binding(
                    get: { viewModel.pendingImages },
                    set: { viewModel.pendingImages = $0 }
                ),
                onSend: viewModel.sendCurrentInput,
                onStop: viewModel.stopGenerating
            )
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(chat.modelID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let usage = viewModel.lastTokenUsage {
                            Text("\(usage.formattedTotal)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(PorchTheme.accent)
                        }
                    }
                }
                .frame(maxWidth: 260)
            }

            if settings.isGitHubConnectorEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingGitHubContextSheet = true
                    } label: {
                        Label {
                            Text(chat.githubContext?.repo ?? "Select Repo")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(chat.githubContext == nil ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isStreaming || viewModel.pendingGitHubWriteApproval != nil)
                    .accessibilityLabel(
                        chat.githubContext == nil
                            ? "Select GitHub repository and branch"
                            : "Change GitHub repository and branch"
                    )
                    .accessibilityValue(
                        chat.githubContext.map { "\($0.repositoryLabel), branch \($0.branch)" } ?? "No repository selected"
                    )
                }
            }
        }
        .sheet(
            item: Binding(
                get: { viewModel.pendingGitHubWriteApproval },
                set: { newValue in
                    guard newValue == nil, viewModel.pendingGitHubWriteApproval != nil else { return }
                    viewModel.cancelPendingGitHubWriteApproval()
                }
            )
        ) { approval in
            NavigationStack {
                GitHubWriteApprovalSheet(approval: approval) { branchName, commitMessage in
                    viewModel.approvePendingGitHubWrite(branchName: branchName, commitMessage: commitMessage)
                } onCancel: {
                    viewModel.cancelPendingGitHubWriteApproval()
                }
            }
            .interactiveDismissDisabled()
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingGitHubContextSheet) {
            NavigationStack {
                GitHubContextSelectionSheet(
                    initialContext: chat.githubContext
                ) { context in
                    chat.applyGitHubContext(context)
                    try? modelContext.save()
                    isShowingGitHubContextSheet = false
                } onClear: {
                    chat.applyGitHubContext(nil)
                    try? modelContext.save()
                    isShowingGitHubContextSheet = false
                } onCancel: {
                    isShowingGitHubContextSheet = false
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var persistedBubbleModels: [MessageBubbleModel] {
        let lastPersistedMessageID = messages.last?.id
        return messages.map { message in
            MessageBubbleModel(
                message: message,
                isRegenerateEnabled: !viewModel.isStreaming
                    && message.role == .assistant
                    && message.id == lastPersistedMessageID,
                isEditEnabled: !viewModel.isStreaming && message.role == .user
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
        let hasContent = !viewModel.streamingText.isEmpty
        let hasThinking = !viewModel.streamingThinkingText.isEmpty
        guard viewModel.isStreaming, hasContent || hasThinking || viewModel.isModelThinking else {
            return nil
        }

        return MessageBubbleModel(
            id: .streaming,
            role: .assistant,
            content: viewModel.streamingText,
            createdAt: nil,
            isPartial: false,
            finishReason: nil,
            isStreaming: true,
            isRegenerateEnabled: false,
            isEditEnabled: false,
            thinkingContent: hasThinking ? viewModel.streamingThinkingText : nil,
            isModelThinking: viewModel.isModelThinking,
            tokenUsage: viewModel.lastTokenUsage
        )
    }

    private var messageList: some View {
        ScrollView {
            messageStack
                .scrollTargetLayout()
        }
        .background(PorchTheme.chatBackground)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition)
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
            Button {
                scrollToBottom(animation: .spring(duration: 0.2))
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, PorchTheme.accent)
                    .shadow(radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 12)
            .opacity(isNearBottom ? 0 : 1)
            .allowsHitTesting(!isNearBottom)
            .animation(.easeInOut(duration: 0.15), value: isNearBottom)
        }
    }

    private var messageStack: some View {
        LazyVStack(alignment: .leading, spacing: PorchTheme.messageVerticalSpacing) {
            if settings.isGitHubConnectorEnabled, chat.githubContext == nil {
                gitHubContextHint
            }

            ForEach(persistedBubbleModels) { bubble in
                MessageBubble(
                    model: bubble,
                    onRegenerate: viewModel.regenerateLastResponse,
                    onEdit: beginEditingMessage(_:),
                    onNavigateBranch: nil
                )
                .equatable()
                .id(bubble.id)
            }

            if let streamingBubbleModel {
                MessageBubble(
                    model: streamingBubbleModel,
                    onRegenerate: {},
                    onEdit: { _ in },
                    onNavigateBranch: nil
                )
                .id(MessageBubbleID.streaming)
            }
        }
        .frame(maxWidth: PorchTheme.maxContentWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .sheet(item: $editingDraft) { draft in
            NavigationStack {
                MessageEditSheet(draft: draft) { updatedText in
                    viewModel.editUserMessageAndResend(messageID: draft.id, newText: updatedText)
                    editingDraft = nil
                } onCancel: {
                    editingDraft = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var gitHubContextHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Select a GitHub repo to enable repo-aware tools in this chat.", systemImage: "shippingbox")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Button("Select Repository") {
                isShowingGitHubContextSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(PorchTheme.accent)
            .disabled(viewModel.isStreaming || viewModel.pendingGitHubWriteApproval != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PorchTheme.inputFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 18)
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

    private func beginEditingMessage(_ messageID: UUID) {
        guard
            let targetIndex = messages.firstIndex(where: { $0.id == messageID }),
            messages[targetIndex].role == .user
        else {
            return
        }

        let message = messages[targetIndex]
        editingDraft = MessageEditDraft(
            id: message.id,
            originalContent: message.content,
            discardsLaterMessages: ChatEditResendPolicy.requiresDiscardConfirmation(
                for: messageID,
                in: messages
            )
        )
    }
}

private struct MessageEditDraft: Identifiable {
    let id: UUID
    let originalContent: String
    let discardsLaterMessages: Bool
}

private struct MessageEditSheet: View {
    let draft: MessageEditDraft
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var isShowingDiscardConfirmation = false

    init(
        draft: MessageEditDraft,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._text = State(initialValue: draft.originalContent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextEditor(text: $text)
                .padding(12)
                .background(PorchTheme.inputFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if draft.discardsLaterMessages {
                Label("Resending this edit will remove all later messages in the conversation.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(PorchTheme.chatBackground)
        .navigationTitle("Edit Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Resend") {
                    if draft.discardsLaterMessages {
                        isShowingDiscardConfirmation = true
                    } else {
                        submit()
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog(
            "Discard later messages?",
            isPresented: $isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Later Messages & Resend", role: .destructive) {
                submit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages after this one will be removed before Porch requests a new assistant reply.")
        }
    }

    private func submit() {
        onSubmit(text)
    }
}
