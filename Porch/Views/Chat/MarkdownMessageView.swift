import MarkdownUI
import SwiftUI

struct MarkdownMessageView: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
    }
}
