import SwiftUI

struct ToolCallBubble: View {
    let toolName: String
    let arguments: String?
    let result: String?
    let isToolResult: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if isExpanded, let displayContent {
                expandedContent(displayContent)
            }
        }
        .padding(PorchTheme.messageInternalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06))
    }

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isToolResult ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    .foregroundStyle(isToolResult ? .green : .blue)
                    .font(.system(size: 14))

                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        let mapping: [String: String] = [
            "github_search_repos": "Searched repositories",
            "github_get_repo_contents": "Browsed file tree",
            "github_get_file_content": "Read file content",
            "github_list_issues": "Listed issues",
            "github_get_issue": "Fetched issue",
            "github_list_pull_requests": "Listed pull requests",
            "github_get_pull_request": "Fetched pull request"
        ]
        if isToolResult {
            return mapping[toolName] ?? "Tool: \(toolName)"
        }
        let callMapping: [String: String] = [
            "github_search_repos": "Searching repositories...",
            "github_get_repo_contents": "Browsing file tree...",
            "github_get_file_content": "Reading file...",
            "github_list_issues": "Listing issues...",
            "github_get_issue": "Fetching issue...",
            "github_list_pull_requests": "Listing pull requests...",
            "github_get_pull_request": "Fetching pull request..."
        ]
        return callMapping[toolName] ?? "Calling \(toolName)"
    }

    private var displayContent: String? {
        if isToolResult {
            return result
        }
        return arguments
    }

    private func expandedContent(_ content: String) -> some View {
        let truncated = content.count > 2000 ? String(content.prefix(2000)) + "\n\n[Truncated]" : content
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(truncated)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: 300)
        .background(PorchTheme.inputFieldBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
