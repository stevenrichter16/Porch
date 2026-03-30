import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum MessageBubbleID: Hashable, Sendable {
    case persisted(UUID)
    case streaming
}

struct MessageBubbleModel: Identifiable, Equatable {
    let id: MessageBubbleID
    let role: MessageRole
    let content: String
    let createdAt: Date?
    let isPartial: Bool
    let finishReason: ChatFinishReason?
    let isStreaming: Bool
    let isRegenerateEnabled: Bool
    let isEditEnabled: Bool
    let toolCallName: String?
    let toolCallArguments: String?
    let toolCallResult: String?
    let thinkingContent: String?
    let isModelThinking: Bool
    let tokenUsage: TokenUsage?
    let siblingCount: Int
    let siblingIndex: Int
    let imageData: Data?

    init(message: ChatMessage, isRegenerateEnabled: Bool, isEditEnabled: Bool, siblingCount: Int = 1, siblingIndex: Int = 0) {
        self.id = .persisted(message.id)
        self.role = message.role
        self.content = message.content
        self.createdAt = message.createdAt
        self.isPartial = message.isPartial
        self.finishReason = message.finishReason
        self.isStreaming = false
        self.isRegenerateEnabled = isRegenerateEnabled
        self.isEditEnabled = isEditEnabled
        self.toolCallName = message.toolCallName
        self.toolCallArguments = message.toolCallArgumentsJSON
        self.toolCallResult = message.toolCallResultJSON
        self.thinkingContent = message.thinkingContent
        self.isModelThinking = false
        self.tokenUsage = message.promptTokens.flatMap { prompt in
            message.completionTokens.map { completion in
                TokenUsage(promptTokens: prompt, completionTokens: completion)
            }
        }
        self.siblingCount = siblingCount
        self.siblingIndex = siblingIndex
        self.imageData = message.imageData
    }

    init(
        id: MessageBubbleID,
        role: MessageRole,
        content: String,
        createdAt: Date?,
        isPartial: Bool,
        finishReason: ChatFinishReason?,
        isStreaming: Bool,
        isRegenerateEnabled: Bool,
        isEditEnabled: Bool,
        toolCallName: String? = nil,
        toolCallArguments: String? = nil,
        toolCallResult: String? = nil,
        thinkingContent: String? = nil,
        isModelThinking: Bool = false,
        tokenUsage: TokenUsage? = nil,
        siblingCount: Int = 1,
        siblingIndex: Int = 0,
        imageData: Data? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isPartial = isPartial
        self.finishReason = finishReason
        self.isStreaming = isStreaming
        self.isRegenerateEnabled = isRegenerateEnabled
        self.isEditEnabled = isEditEnabled
        self.toolCallName = toolCallName
        self.toolCallArguments = toolCallArguments
        self.toolCallResult = toolCallResult
        self.thinkingContent = thinkingContent
        self.isModelThinking = isModelThinking
        self.tokenUsage = tokenUsage
        self.siblingCount = siblingCount
        self.siblingIndex = siblingIndex
        self.imageData = imageData
    }

    var isToolCall: Bool {
        toolCallName != nil && role == .assistant && finishReason == .toolCalls
    }

    var isToolResult: Bool {
        role == .tool
    }
}

struct MessageBubble: View, Equatable {
    let model: MessageBubbleModel
    let onRegenerate: () -> Void
    let onEdit: (UUID) -> Void

    let onNavigateBranch: ((UUID, BranchDirection) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        if model.isToolCall || model.isToolResult {
            ToolCallBubble(
                toolName: model.toolCallName ?? "unknown",
                arguments: model.toolCallArguments,
                result: model.toolCallResult,
                isToolResult: model.isToolResult
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                headerRow

                if model.isModelThinking, model.thinkingContent?.isEmpty ?? true {
                    ThinkingIndicator()
                }

                if let thinking = model.thinkingContent, !thinking.isEmpty {
                    ThinkingDisclosure(content: thinking, isStreaming: model.isStreaming)
                }

                messageContent

                if model.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   model.thinkingContent != nil,
                   !model.isStreaming {
                    Text("No visible response — only reasoning was produced.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                if model.isPartial || model.finishReason == .cancelled {
                    statusCapsule(text: "Partial")
                } else if let reason = model.finishReason, case .length = reason {
                    statusCapsule(text: "Max tokens reached")
                }

                if shouldShowFooter {
                    footerRow
                }
            }
            .padding(PorchTheme.messageInternalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            roleLabel

            Spacer(minLength: 0)

            if model.role == .user, model.isEditEnabled, let persistedMessageID {
                MessageEditButton {
                    onEdit(persistedMessageID)
                }
            }

            MessageCopyButton(
                content: model.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (model.thinkingContent ?? "")
                    : model.content
            )
        }
    }

    private var roleLabel: some View {
        Label(
            model.role == .user ? "You" : "Assistant",
            systemImage: model.role == .user ? "person.fill" : "cpu"
        )
        .font(PorchTheme.roleLabelFont)
        .foregroundStyle(model.role == .user ? PorchTheme.userRoleLabel : PorchTheme.assistantRoleLabel)
    }

    @ViewBuilder
    private var messageContent: some View {
        #if canImport(UIKit)
        if let imageData = model.imageData, let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280, maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        #endif

        switch (model.role, model.isStreaming) {
        case (.assistant, true):
            SelectableMessageTextView(content: model.content, kind: .plainText)
                .frame(maxWidth: .infinity, alignment: .leading)
        case (.assistant, false):
            MarkdownMessageView(content: model.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            SelectableMessageTextView(content: model.content, kind: .plainText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if let createdAt = model.createdAt {
                Text(MessageTimestampFormatter.string(for: createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let usage = model.tokenUsage, usage.totalTokens > 0 {
                TokenUsagePill(usage: usage)
            }

            if model.siblingCount > 1, let persistedID = persistedMessageID {
                BranchNavigator(
                    currentIndex: model.siblingIndex,
                    totalCount: model.siblingCount,
                    onNavigate: { direction in
                        onNavigateBranch?(persistedID, direction)
                    }
                )
            }

            Spacer(minLength: 0)

            if model.role == .assistant, model.isRegenerateEnabled, !model.isStreaming {
                MessageActionRow(
                    showRegenerate: true,
                    onRegenerate: onRegenerate
                )
            }
        }
    }

    private var shouldShowFooter: Bool {
        model.createdAt != nil
        || (model.role == .assistant && model.isRegenerateEnabled && !model.isStreaming)
        || model.tokenUsage != nil
        || model.siblingCount > 1
    }

    private var persistedMessageID: UUID? {
        guard case .persisted(let messageID) = model.id else {
            return nil
        }

        return messageID
    }

    private var rowBackground: Color {
        switch model.role {
        case .user:
            PorchTheme.userRowBackground
        case .assistant:
            PorchTheme.assistantRowBackground
        case .system:
            Color.orange.opacity(0.08)
        case .tool:
            Color.purple.opacity(0.06)
        }
    }

    private func statusCapsule(text: String) -> some View {
        Text(text)
            .font(PorchTheme.statusCapsuleFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PorchTheme.inputFieldBackground)
            .clipShape(Capsule())
    }
}

private struct MessageActionRow: View {
    let showRegenerate: Bool
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if showRegenerate {
                Button(action: onRegenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
        .foregroundStyle(PorchTheme.actionButtonColor)
    }
}

private struct MessageEditButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PorchTheme.actionButtonColor)
                .frame(width: 28, height: 28)
                .background(PorchTheme.inputFieldBackground.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit message")
    }
}

private struct MessageCopyButton: View {
    let content: String

    @State private var didCopy = false

    var body: some View {
        Button(action: copyMessage) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(didCopy ? PorchTheme.accent : PorchTheme.actionButtonColor)
                .frame(width: 28, height: 28)
                .background(PorchTheme.inputFieldBackground.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(content.isEmpty)
        .accessibilityLabel(didCopy ? "Copied" : "Copy message")
    }

    private func copyMessage() {
        guard !content.isEmpty else { return }

        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif

        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}

// MARK: - Thinking Mode Views

private struct ThinkingIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.caption2)
            Text("Thinking...")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(PorchTheme.accent)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                opacity = 1.0
            }
        }
    }
}

struct ThinkingDisclosure: View {
    let content: String
    let isStreaming: Bool
    @State private var isExpanded: Bool
    @State private var hasManuallyToggled = false

    init(content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
        self._isExpanded = State(initialValue: isStreaming)
    }

    // Collapse automatically when streaming ends, unless user manually toggled
    private func syncExpansionWithStreaming(_ streaming: Bool) {
        if !streaming, !hasManuallyToggled {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                hasManuallyToggled = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text("Thought for a moment")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onChange(of: isStreaming) { _, newValue in
                syncExpansionWithStreaming(newValue)
            }

            if isExpanded {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                .background(PorchTheme.inputFieldBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

// MARK: - Token Usage

struct TokenUsagePill: View {
    let usage: TokenUsage

    var body: some View {
        Text("\(usage.formattedTotal) tokens")
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(PorchTheme.inputFieldBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Branch Navigation

enum BranchDirection {
    case previous
    case next
}

struct BranchNavigator: View {
    let currentIndex: Int
    let totalCount: Int
    let onNavigate: (BranchDirection) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { onNavigate(.previous) } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))
            }
            .disabled(currentIndex == 0)
            .buttonStyle(.plain)

            Text("\(currentIndex + 1)/\(totalCount)")
                .font(.caption2.weight(.medium))

            Button { onNavigate(.next) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .disabled(currentIndex >= totalCount - 1)
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
    }
}
