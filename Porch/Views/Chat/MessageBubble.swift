import SwiftUI

enum MessageBubbleID: Hashable, Sendable {
    case persisted(UUID)
    case streaming
}

struct MessageBubbleModel: Identifiable, Equatable {
    let id: MessageBubbleID
    let role: MessageRole
    let content: String
    let isPartial: Bool
    let finishReason: ChatFinishReason?
    let isStreaming: Bool
    let isRegenerateEnabled: Bool

    init(message: ChatMessage, isRegenerateEnabled: Bool) {
        self.id = .persisted(message.id)
        self.role = message.role
        self.content = message.content
        self.isPartial = message.isPartial
        self.finishReason = message.finishReason
        self.isStreaming = false
        self.isRegenerateEnabled = isRegenerateEnabled
    }

    init(
        id: MessageBubbleID,
        role: MessageRole,
        content: String,
        isPartial: Bool,
        finishReason: ChatFinishReason?,
        isStreaming: Bool,
        isRegenerateEnabled: Bool
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isPartial = isPartial
        self.finishReason = finishReason
        self.isStreaming = isStreaming
        self.isRegenerateEnabled = isRegenerateEnabled
    }
}

struct MessageBubble: View, Equatable {
    let model: MessageBubbleModel
    let onRegenerate: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if model.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: bubbleAlignment, spacing: 6) {
                bubbleContent
                    .padding(14)
                    .frame(maxWidth: 520, alignment: bubbleAlignment == .leading ? .leading : .trailing)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if model.role == .assistant {
                    MessageActionRow(
                        content: model.content,
                        showRegenerate: model.isRegenerateEnabled && !model.isStreaming,
                        onRegenerate: onRegenerate
                    )
                }

                if model.isPartial || model.finishReason == .cancelled {
                    statusCapsule(text: "Partial")
                } else if let reason = model.finishReason, case .length = reason {
                    statusCapsule(text: "Max tokens reached")
                }
            }

            if model.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch (model.role, model.isStreaming) {
        case (.assistant, true):
            Text(model.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        case (.assistant, false):
            MarkdownMessageView(content: model.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
        default:
            Text(model.content)
                .frame(maxWidth: .infinity, alignment: model.role == .user ? .trailing : .leading)
                .textSelection(.enabled)
                .foregroundStyle(model.role == .user ? .white : .primary)
        }
    }

    private var bubbleBackground: Color {
        switch model.role {
        case .user:
            Color.blue
        case .assistant:
            Color(.secondarySystemBackground)
        case .system:
            Color.orange.opacity(0.18)
        }
    }

    private var bubbleAlignment: HorizontalAlignment {
        model.role == .user ? .trailing : .leading
    }

    private func statusCapsule(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemBackground))
            .clipShape(Capsule())
    }
}

private struct MessageActionRow: View {
    let content: String
    let showRegenerate: Bool
    let onRegenerate: () -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: copyMessage) {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)

            if showRegenerate {
                Button(action: onRegenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func copyMessage() {
        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}
