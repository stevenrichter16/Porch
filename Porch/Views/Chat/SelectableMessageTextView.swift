import SwiftUI

#if canImport(UIKit)
import UIKit

enum SelectableMessageTextKind: Equatable {
    case plainText
}

struct SelectableMessageTextView: UIViewRepresentable {
    let content: String
    let kind: SelectableMessageTextKind

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(PorchTheme.accent)
        ]
        textView.tintColor = UIColor(PorchTheme.accent)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let configuration = RenderConfiguration(
            content: content,
            kind: kind,
            colorScheme: colorScheme
        )

        guard context.coordinator.lastConfiguration != configuration else { return }

        uiView.attributedText = MessageTextRenderer.makeAttributedText(
            for: content,
            kind: kind,
            colorScheme: colorScheme
        )
        context.coordinator.lastConfiguration = configuration
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }

        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: fittingSize.height)
    }
}

extension SelectableMessageTextView {
    final class Coordinator {
        var lastConfiguration: RenderConfiguration?
    }

    struct RenderConfiguration: Equatable {
        let content: String
        let kind: SelectableMessageTextKind
        let colorScheme: ColorScheme
    }
}

private enum MessageTextRenderer {
    static func makeAttributedText(
        for content: String,
        kind: SelectableMessageTextKind,
        colorScheme: ColorScheme
    ) -> NSAttributedString {
        switch kind {
        case .plainText:
            return plainText(content, colorScheme: colorScheme)
        }
    }

    private static func plainText(_ content: String, colorScheme: ColorScheme) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 3

        return NSAttributedString(
            string: content,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: resolvedColor(.label, colorScheme: colorScheme),
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private static func resolvedColor(
        _ color: UIColor,
        colorScheme: ColorScheme
    ) -> UIColor {
        let interfaceStyle: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: interfaceStyle))
    }

}
#endif
