import SwiftUI

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

    init(message: ChatMessage, isRegenerateEnabled: Bool, isEditEnabled: Bool) {
        self.id = .persisted(message.id)
        self.role = message.role
        self.content = message.content
        self.createdAt = message.createdAt
        self.isPartial = message.isPartial
        self.finishReason = message.finishReason
        self.isStreaming = false
        self.isRegenerateEnabled = isRegenerateEnabled
        self.isEditEnabled = isEditEnabled
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
        isEditEnabled: Bool
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
    }
}

struct MessageBubble: View, Equatable {
    let model: MessageBubbleModel
    let onRegenerate: () -> Void
    let onEdit: (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            messageContent

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

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            roleLabel

            Spacer(minLength: 0)

            if model.role == .user, model.isEditEnabled, let persistedMessageID {
                MessageEditButton {
                    onEdit(persistedMessageID)
                }
            }

            MessageCopyButton(content: model.content)
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
        model.createdAt != nil || (model.role == .assistant && model.isRegenerateEnabled && !model.isStreaming)
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
