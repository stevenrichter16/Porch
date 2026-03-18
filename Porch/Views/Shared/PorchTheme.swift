import MarkdownUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum PorchTheme {

    // MARK: - Colors

    static let chatBackground = Color("ChatBackground")
    static let assistantRowBackground = Color("AssistantRowBackground")
    static let userRowBackground = Color.clear
    static let userRoleLabel = Color("UserRoleLabel")
    static let assistantRoleLabel = Color("AssistantRoleLabel")
    static let accent = Color("PorchAccent")
    static let inputFieldBackground = Color("InputFieldBackground")
    static let messageDivider = Color("MessageDivider")
    static let errorBanner = Color("ErrorBanner")

    // MARK: - Spacing

    static let messageVerticalSpacing: CGFloat = 4
    static let messageInternalPadding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    static let maxContentWidth: CGFloat = 720
    static let sendButtonSize: CGFloat = 36
    static let inputFieldCornerRadius: CGFloat = 22

    // MARK: - Typography

    static let roleLabelFont: Font = .caption.weight(.semibold)
    static let messageBodyFont: Font = .body
    static let statusCapsuleFont: Font = .caption2.weight(.medium)

    // MARK: - Action Button

    static let actionButtonColor = Color.secondary

    // MARK: - Markdown Theme

    static let markdownTheme: MarkdownUI.Theme = .gitHub.text {
        ForegroundColor(.primary)
        FontSize(16)
    }.code {
        FontFamilyVariant(.monospaced)
        BackgroundColor(.clear)
    }.codeBlock { configuration in
        PorchMarkdownCodeBlock(configuration: configuration)
    }
}

enum MarkdownCodeBlockPresentation {
    static func languageLabel(for language: String?) -> String {
        let token = language?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token, !token.isEmpty else {
            return "Code"
        }

        return token
    }
}

private struct PorchMarkdownCodeBlock: View {
    let configuration: CodeBlockConfiguration

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(MarkdownCodeBlockPresentation.languageLabel(for: configuration.language))
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                MarkdownCodeBlockCopyButton(content: configuration.content)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PorchTheme.chatBackground)

            Divider()
                .overlay(PorchTheme.messageDivider)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(16)
            }
        }
        .background(PorchTheme.inputFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .markdownMargin(top: .em(0.8), bottom: .em(0.8))
    }
}

private struct MarkdownCodeBlockCopyButton: View {
    let content: String

    @State private var didCopy = false

    var body: some View {
        Button(action: copyCode) {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.medium))
                .foregroundStyle(didCopy ? PorchTheme.accent : PorchTheme.actionButtonColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied code block" : "Copy code block")
    }

    private func copyCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif

        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}
