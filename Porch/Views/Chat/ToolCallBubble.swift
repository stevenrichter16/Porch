import Foundation
import SwiftUI

struct ToolCallBubble: View {
    let toolName: String
    let arguments: String?
    let result: String?
    let isToolResult: Bool
    let repositoryLabel: String?
    let branch: String?
    let statusLabel: String?
    let isLiveActivity: Bool

    @State private var isExpanded = false

    var body: some View {
        let presentation = ToolCallPresentation.make(
            toolName: toolName,
            arguments: arguments,
            result: result,
            isToolResult: isToolResult,
            repositoryLabel: repositoryLabel,
            branch: branch,
            statusLabel: statusLabel,
            isLiveActivity: isLiveActivity
        )

        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    leadingIndicator(for: presentation)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(presentation.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            if let badge = presentation.statusBadge {
                                statusBadge(text: badge, color: presentation.statusColor)
                            }
                        }

                        Text(presentation.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isExpanded ? nil : 3)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let rawDetails = presentation.rawDetails {
                expandedContent(rawDetails)
            }
        }
        .padding(PorchTheme.messageInternalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(presentation.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func leadingIndicator(for presentation: ToolCallPresentation) -> some View {
        if presentation.showsProgress {
            ProgressView()
                .controlSize(.small)
                .tint(presentation.statusColor)
                .frame(width: 16, height: 16)
                .padding(.top, 3)
        } else {
            Image(systemName: presentation.iconName)
                .foregroundStyle(presentation.statusColor)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 16, height: 16)
                .padding(.top, 3)
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func expandedContent(_ content: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .background(PorchTheme.inputFieldBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ToolCallPresentation {
    let title: String
    let summary: String
    let rawDetails: String?
    let iconName: String
    let statusBadge: String?
    let statusColor: Color
    let backgroundColor: Color
    let showsProgress: Bool

    static func make(
        toolName: String,
        arguments: String?,
        result: String?,
        isToolResult: Bool,
        repositoryLabel: String?,
        branch: String?,
        statusLabel: String?,
        isLiveActivity: Bool
    ) -> Self {
        if isLiveActivity {
            return makeLive(
                toolName: toolName,
                arguments: arguments,
                repositoryLabel: repositoryLabel,
                branch: branch,
                statusLabel: statusLabel
            )
        }

        if isToolResult {
            return makeResult(
                toolName: toolName,
                arguments: arguments,
                result: result,
                repositoryLabel: repositoryLabel,
                branch: branch
            )
        }

        return makePlannedCall(
            toolName: toolName,
            arguments: arguments,
            repositoryLabel: repositoryLabel,
            branch: branch
        )
    }

    private static func makeLive(
        toolName: String,
        arguments: String?,
        repositoryLabel: String?,
        branch: String?,
        statusLabel: String?
    ) -> Self {
        let summary = summaryForCall(
            toolName: toolName,
            arguments: arguments,
            repositoryLabel: repositoryLabel,
            branch: branch
        )
        return Self(
            title: title(for: toolName, fallback: "GitHub Action"),
            summary: summary,
            rawDetails: prettyPrintedJSON(arguments),
            iconName: "hourglass",
            statusBadge: statusLabel ?? "Running",
            statusColor: PorchTheme.accent,
            backgroundColor: PorchTheme.accent.opacity(0.09),
            showsProgress: true
        )
    }

    private static func makePlannedCall(
        toolName: String,
        arguments: String?,
        repositoryLabel: String?,
        branch: String?
    ) -> Self {
        let toolCalls = toolCalls(from: arguments)
        let summary: String
        let titleText: String

        if toolCalls.count > 1 {
            let scope = repositoryBranchLabel(
                repository: repositoryLabel,
                branch: branch
            )
            let steps = toolCalls
                .prefix(3)
                .map { shortActionPhrase(toolName: $0.name, arguments: $0.arguments) }
                .joined(separator: "; ")
            let remainingCount = max(toolCalls.count - 3, 0)
            summary = "Queued \(toolCalls.count) tool actions\(scope.map { " in \($0)" } ?? ""). \(steps)\(remainingCount > 0 ? "; +\(remainingCount) more." : ".")"
            titleText = "Tool Actions"
        } else {
            let normalizedArguments = toolCalls.first?.arguments ?? arguments
            let normalizedToolName = toolCalls.first?.name ?? toolName
            summary = summaryForCall(
                toolName: normalizedToolName,
                arguments: normalizedArguments,
                repositoryLabel: repositoryLabel,
                branch: branch
            )
            titleText = title(for: normalizedToolName, fallback: "Tool Call")
        }

        return Self(
            title: titleText,
            summary: summary,
            rawDetails: prettyPrintedJSON(arguments),
            iconName: "list.bullet.rectangle.portrait",
            statusBadge: "Queued",
            statusColor: PorchTheme.accent,
            backgroundColor: PorchTheme.inputFieldBackground.opacity(0.92),
            showsProgress: false
        )
    }

    private static func makeResult(
        toolName: String,
        arguments: String?,
        result: String?,
        repositoryLabel: String?,
        branch: String?
    ) -> Self {
        let resultObject = jsonObject(from: result)
        let summary = summaryForResult(
            toolName: toolName,
            arguments: arguments,
            resultObject: resultObject,
            repositoryLabel: repositoryLabel,
            branch: branch,
            rawResult: result
        )
        let style = resultStyle(
            toolName: toolName,
            resultObject: resultObject,
            rawResult: result
        )

        return Self(
            title: title(for: toolName, fallback: "Tool Result"),
            summary: summary,
            rawDetails: prettyPrintedJSON(result) ?? prettyPrintedJSON(arguments),
            iconName: style.iconName,
            statusBadge: style.badge,
            statusColor: style.color,
            backgroundColor: style.backgroundColor,
            showsProgress: false
        )
    }

    private static func title(for toolName: String, fallback: String) -> String {
        let mapping: [String: String] = [
            "multi_tool_call": "Tool Actions",
            "web_search": "Web Search",
            "web_fetch_page": "Web Fetch",
            "github_search_repos": "Repository Search",
            "github_search_paths": "Path Search",
            "github_search_code": "Code Search",
            "github_get_repo_tree": "Repository Tree",
            "github_get_repo_contents": "Folder Browse",
            "github_get_file_content": "File Read",
            "github_get_file_lines": "Line Read",
            "github_get_file_tail": "Tail Read",
            "github_list_branches": "Branch List",
            "github_list_commits": "Commit List",
            "github_compare_refs": "Ref Compare",
            "github_list_issues": "Issue List",
            "github_search_issues": "Issue Search",
            "github_get_issue": "Issue Read",
            "github_list_pull_requests": "Pull Request List",
            "github_search_pull_requests": "Pull Request Search",
            "github_get_pull_request": "Pull Request Read",
            "github_get_pull_request_files": "Pull Request Files",
            "github_get_pull_request_diff": "Pull Request Diff",
            "github_commit_file_changes": "GitHub Write"
        ]
        return mapping[toolName] ?? fallback
    }

    private static func summaryForCall(
        toolName: String,
        arguments: String?,
        repositoryLabel: String?,
        branch: String?
    ) -> String {
        let args = jsonObject(from: arguments)
        let scope = repositoryBranchLabel(
            repository: repositoryLabel,
            branch: branch
        )

        switch toolName {
        case "github_search_paths":
            let query = stringValue(in: args, key: "query") ?? "the requested terms"
            return "Searching repository paths for \"\(query)\"\(scope.map { " in \($0)" } ?? "")."

        case "github_search_code":
            let query = stringValue(in: args, key: "query") ?? "the requested terms"
            return "Searching repository code for \"\(query)\"\(scope.map { " in \($0)" } ?? "")."

        case "github_get_repo_tree":
            let pathPrefix = stringValue(in: args, key: "path_prefix") ?? "/"
            return "Scanning the repository tree under \(pathPrefix)\(scope.map { " in \($0)" } ?? "")."

        case "github_get_repo_contents":
            let path = stringValue(in: args, key: "path") ?? "/"
            return "Browsing the repository folder \(path)\(scope.map { " in \($0)" } ?? "")."

        case "github_get_file_content":
            let path = stringValue(in: args, key: "path") ?? "the requested file"
            return "Reading \(path)\(scope.map { " from \($0)" } ?? "")."

        case "github_get_file_lines":
            let path = stringValue(in: args, key: "path") ?? "the requested file"
            if let startLine = intValue(in: args, key: "start_line"),
               let endLine = intValue(in: args, key: "end_line") {
                return "Reading \(path) lines \(startLine)-\(endLine)\(scope.map { " from \($0)" } ?? "")."
            }
            return "Reading a bounded line window from \(path)\(scope.map { " in \($0)" } ?? "")."

        case "github_get_file_tail":
            let path = stringValue(in: args, key: "path") ?? "the requested file"
            return "Reading the tail of \(path)\(scope.map { " in \($0)" } ?? "")."

        case "github_list_branches":
            return "Listing branches\(scope.map { " for \($0)" } ?? "")."

        case "github_list_commits":
            let ref = stringValue(in: args, key: "ref")
            return "Listing recent commits\(scope.map { " in \($0)" } ?? "")\(ref.map { " for \($0)" } ?? "")."

        case "github_compare_refs":
            let base = stringValue(in: args, key: "base") ?? "base"
            let head = stringValue(in: args, key: "head") ?? "head"
            return "Comparing \(base) to \(head)\(scope.map { " in \($0)" } ?? "")."

        case "github_list_issues":
            return "Listing issues\(scope.map { " in \($0)" } ?? "")."

        case "github_search_issues":
            let query = stringValue(in: args, key: "query") ?? "the requested terms"
            return "Searching issues for \"\(query)\"\(scope.map { " in \($0)" } ?? "")."

        case "github_get_issue":
            let number = intValue(in: args, key: "number")
            return "Reading issue #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "")."

        case "github_list_pull_requests":
            return "Listing pull requests\(scope.map { " in \($0)" } ?? "")."

        case "github_search_pull_requests":
            let query = stringValue(in: args, key: "query") ?? "the requested terms"
            return "Searching pull requests for \"\(query)\"\(scope.map { " in \($0)" } ?? "")."

        case "github_get_pull_request":
            let number = intValue(in: args, key: "number")
            return "Reading pull request #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "")."

        case "github_get_pull_request_files":
            let number = intValue(in: args, key: "number")
            return "Listing files for pull request #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "")."

        case "github_get_pull_request_diff":
            let number = intValue(in: args, key: "number")
            return "Reading the unified diff for pull request #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "")."

        case "github_commit_file_changes":
            let paths = changedPaths(from: args)
            let pathSummary = formatPathList(paths, maxCount: 3)
            if let pathSummary {
                return "Preparing GitHub changes\(scope.map { " in \($0)" } ?? "") touching \(pathSummary)."
            }
            return "Preparing GitHub file changes\(scope.map { " in \($0)" } ?? "")."

        default:
            return "Calling \(toolName)\(scope.map { " in \($0)" } ?? "")."
        }
    }

    private static func summaryForResult(
        toolName: String,
        arguments: String?,
        resultObject: [String: Any]?,
        repositoryLabel: String?,
        branch: String?,
        rawResult: String?
    ) -> String {
        if let error = stringValue(in: resultObject, key: "error"), !error.isEmpty {
            return "The \(title(for: toolName, fallback: "tool")) request failed: \(error)"
        }

        if let status = stringValue(in: resultObject, key: "status") {
            switch status {
            case "redundant_call":
                let reason = stringValue(in: resultObject, key: "reason") ?? "Repeated GitHub action."
                if let suggestedPaths = stringArray(in: resultObject, key: "suggested_paths"),
                   let formattedPaths = formatPathList(suggestedPaths, maxCount: 3) {
                    return "\(reason) Reuse \(formattedPaths)."
                }
                return reason

            case "tools_disabled":
                let reason = stringValue(in: resultObject, key: "reason") ?? "GitHub tool use is closed for this run."
                return reason

            case "cancelled":
                return stringValue(in: resultObject, key: "reason") ?? "This GitHub action was cancelled."

            default:
                break
            }
        }

        let args = jsonObject(from: arguments)
        let scope = repositoryBranchLabel(
            repository: stringValue(in: resultObject, key: "repository") ?? repositoryLabel,
            branch: stringValue(in: resultObject, key: "branch") ?? branch
        )

        switch toolName {
        case "github_search_paths":
            let query = stringValue(in: resultObject, key: "query") ??
                stringValue(in: args, key: "query") ?? "the requested terms"
            let returnedCount = intValue(in: resultObject, key: "returned_count")
            let totalCount = intValue(in: resultObject, key: "total_matching_count")
            let paths = dictArray(in: resultObject, key: "results").compactMap { stringValue(in: $0, key: "path") }
            let countSummary = matchCountSummary(returnedCount: returnedCount, totalCount: totalCount)
            let pathSummary = formatPathList(paths, maxCount: 3)
            return "Searched repository paths for \"\(query)\"\(scope.map { " in \($0)" } ?? ""). \(countSummary)\(pathSummary.map { " Top matches: \($0)." } ?? "")"

        case "github_search_code":
            let query = stringValue(in: resultObject, key: "query") ??
                stringValue(in: args, key: "query") ?? "the requested terms"
            let returnedCount = intValue(in: resultObject, key: "returned_count")
            let searchedFiles = intValue(in: resultObject, key: "searched_files")
            let paths = dictArray(in: resultObject, key: "results").compactMap { stringValue(in: $0, key: "path") }
            let countSummary = codeCountSummary(returnedCount: returnedCount, searchedFiles: searchedFiles)
            let pathSummary = formatPathList(paths, maxCount: 3)
            return "Searched repository code for \"\(query)\"\(scope.map { " in \($0)" } ?? ""). \(countSummary)\(pathSummary.map { " Strongest hits: \($0)." } ?? "")"

        case "github_get_repo_tree":
            let pathPrefix = stringValue(in: resultObject, key: "path_prefix") ??
                stringValue(in: args, key: "path_prefix") ?? "/"
            let returnedCount = intValue(in: resultObject, key: "returned_count")
            let totalCount = intValue(in: resultObject, key: "total_matching_count")
            let paths = dictArray(in: resultObject, key: "entries").compactMap { stringValue(in: $0, key: "path") }
            let countSummary = matchCountSummary(returnedCount: returnedCount, totalCount: totalCount)
            let pathSummary = formatPathList(paths, maxCount: 3)
            return "Scanned the repository tree under \(pathPrefix)\(scope.map { " in \($0)" } ?? ""). \(countSummary)\(pathSummary.map { " Included: \($0)." } ?? "")"

        case "github_get_repo_contents":
            let path = stringValue(in: args, key: "path") ?? "/"
            let paths = dictArray(in: resultObject, key: "entries").compactMap { stringValue(in: $0, key: "path") }
            let pathSummary = formatPathList(paths, maxCount: 3)
            return "Browsed \(path)\(scope.map { " in \($0)" } ?? "").\(pathSummary.map { " Returned: \($0)." } ?? "")"

        case "github_get_file_content":
            let path = stringValue(in: resultObject, key: "path") ??
                stringValue(in: args, key: "path") ?? "the requested file"
            let size = stringValue(in: resultObject, key: "size") ?? intValue(in: resultObject, key: "size").map(String.init)
            let truncated = boolValue(in: resultObject, key: "truncated") ??
                (stringValue(in: resultObject, key: "truncated") == "true")
            var summary = "Read \(path)\(scope.map { " from \($0)" } ?? "")."
            if let size {
                summary += " File size: \(size) bytes."
            }
            if truncated {
                summary += " Returned truncated content."
            }
            return summary

        case "github_get_file_lines":
            let path = stringValue(in: resultObject, key: "path") ??
                stringValue(in: args, key: "path") ?? "the requested file"
            let startLine = intValue(in: resultObject, key: "start_line")
            let endLine = intValue(in: resultObject, key: "end_line")
            let lineCount = intValue(in: resultObject, key: "line_count")
            let truncated = boolValue(in: resultObject, key: "truncated")
            var summary = "Read \(path)"
            if let startLine, let endLine, startLine > 0, endLine > 0 {
                summary += " lines \(startLine)-\(endLine)"
            }
            summary += scope.map { " from \($0)." } ?? "."
            if let lineCount {
                summary += " Returned \(lineCount) lines."
            }
            if truncated == true {
                summary += " Output was truncated."
            }
            return summary

        case "github_get_file_tail":
            let path = stringValue(in: resultObject, key: "path") ??
                stringValue(in: args, key: "path") ?? "the requested file"
            let startLine = intValue(in: resultObject, key: "start_line")
            let endLine = intValue(in: resultObject, key: "end_line")
            let lineCount = intValue(in: resultObject, key: "line_count")
            let truncated = boolValue(in: resultObject, key: "truncated")
            var summary = "Read the tail of \(path)"
            if let startLine, let endLine, startLine > 0, endLine > 0 {
                summary += " covering lines \(startLine)-\(endLine)"
            }
            summary += scope.map { " in \($0)." } ?? "."
            if let lineCount {
                summary += " Returned \(lineCount) lines."
            }
            if truncated == true {
                summary += " Output was truncated."
            }
            return summary

        case "github_list_branches":
            let branches = dictArray(in: resultObject, key: "branches").compactMap { stringValue(in: $0, key: "name") }
            let branchSummary = formatPathList(branches, maxCount: 3)
            return "Listed \(branches.count) branch\(branches.count == 1 ? "" : "es")\(scope.map { " in \($0)" } ?? "").\(branchSummary.map { " Top branches: \($0)." } ?? "")"

        case "github_list_commits":
            let commits = dictArray(in: resultObject, key: "commits")
            let messages = commits.compactMap { stringValue(in: $0, key: "message") }
            let commitSummary = formatPathList(messages, maxCount: 2)
            return "Listed \(commits.count) recent commit\(commits.count == 1 ? "" : "s")\(scope.map { " in \($0)" } ?? "").\(commitSummary.map { " Latest messages: \($0)." } ?? "")"

        case "github_compare_refs":
            let base = stringValue(in: resultObject, key: "base") ?? "base"
            let head = stringValue(in: resultObject, key: "head") ?? "head"
            let fileCount = dictArray(in: resultObject, key: "files").count
            let commitCount = intValue(in: resultObject, key: "total_commits")
            return "Compared \(base) to \(head)\(scope.map { " in \($0)" } ?? "").\(commitCount.map { " \($0) commit\($0 == 1 ? "" : "s")" } ?? "")\(fileCount > 0 ? " and \(fileCount) changed file\(fileCount == 1 ? "" : "s")." : ".")"

        case "github_search_issues", "github_list_issues":
            let items = dictArray(in: resultObject, key: "issues")
            return "Returned \(items.count) issue\(items.count == 1 ? "" : "s")\(scope.map { " in \($0)" } ?? "")."

        case "github_get_issue":
            let number = intValue(in: resultObject, key: "number") ?? intValue(in: args, key: "number")
            let titleText = stringValue(in: resultObject, key: "title")
            return "Read issue #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "").\(titleText.map { " Title: \($0)." } ?? "")"

        case "github_search_pull_requests", "github_list_pull_requests":
            let items = dictArray(in: resultObject, key: "pull_requests")
            return "Returned \(items.count) pull request\(items.count == 1 ? "" : "s")\(scope.map { " in \($0)" } ?? "")."

        case "github_get_pull_request":
            let number = intValue(in: resultObject, key: "number") ?? intValue(in: args, key: "number")
            let titleText = stringValue(in: resultObject, key: "title")
            return "Read pull request #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "").\(titleText.map { " Title: \($0)." } ?? "")"

        case "github_get_pull_request_files":
            let files = dictArray(in: resultObject, key: "files")
            let paths = files.compactMap { stringValue(in: $0, key: "filename") }
            let pathSummary = formatPathList(paths, maxCount: 3)
            return "Listed \(files.count) pull-request file\(files.count == 1 ? "" : "s")\(scope.map { " in \($0)" } ?? "").\(pathSummary.map { " Top files: \($0)." } ?? "")"

        case "github_get_pull_request_diff":
            let number = intValue(in: resultObject, key: "number") ?? intValue(in: args, key: "number")
            let truncated = boolValue(in: resultObject, key: "truncated")
            return "Fetched the unified diff for pull request #\(number.map(String.init) ?? "?")\(scope.map { " in \($0)" } ?? "").\(truncated == true ? " Diff was truncated." : "")"

        case "github_commit_file_changes":
            let changedFiles = intValue(in: resultObject, key: "changed_files")
            let branchName = stringValue(in: resultObject, key: "branch_name")
            let createdCount = intValue(in: resultObject, key: "created_count") ?? 0
            let updatedCount = intValue(in: resultObject, key: "updated_count") ?? 0
            let deletedCount = intValue(in: resultObject, key: "deleted_count") ?? 0
            return "Created GitHub branch \(branchName ?? "(unknown)")\(scope.map { " for \($0)" } ?? ""). Changed \(changedFiles ?? 0) file\(changedFiles == 1 ? "" : "s"): \(createdCount) created, \(updatedCount) updated, \(deletedCount) deleted."

        default:
            if let rawResult, !rawResult.isEmpty {
                return rawResult
            }
            return "Completed \(toolName)."
        }
    }

    private static func resultStyle(
        toolName: String,
        resultObject: [String: Any]?,
        rawResult: String?
    ) -> (iconName: String, badge: String?, color: Color, backgroundColor: Color) {
        if let error = stringValue(in: resultObject, key: "error"), !error.isEmpty {
            return ("exclamationmark.triangle.fill", "Error", PorchTheme.errorBanner, PorchTheme.errorBanner.opacity(0.09))
        }

        if let status = stringValue(in: resultObject, key: "status") {
            switch status {
            case "redundant_call":
                return ("arrow.uturn.backward.circle.fill", "Reused", .orange, .orange.opacity(0.08))
            case "tools_disabled":
                return ("hand.raised.circle.fill", "Blocked", .orange, .orange.opacity(0.08))
            case "cancelled":
                return ("xmark.circle.fill", "Cancelled", .secondary, PorchTheme.inputFieldBackground.opacity(0.9))
            default:
                break
            }
        }

        if let rawResult, rawResult.contains("\"error\"") {
            return ("exclamationmark.triangle.fill", "Error", PorchTheme.errorBanner, PorchTheme.errorBanner.opacity(0.09))
        }

        let successColor: Color = toolName == "github_commit_file_changes" ? PorchTheme.accent : .green
        return ("checkmark.circle.fill", "Done", successColor, successColor.opacity(0.08))
    }

    private static func repositoryBranchLabel(repository: String?, branch: String?) -> String? {
        let trimmedRepository = repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedRepository?.isEmpty == false ? trimmedRepository : nil, trimmedBranch?.isEmpty == false ? trimmedBranch : nil) {
        case let (repository?, branch?):
            return "\(repository)@\(branch)"
        case let (repository?, nil):
            return repository
        case let (nil, branch?):
            return branch
        default:
            return nil
        }
    }

    private static func toolCalls(from rawArguments: String?) -> [(name: String, arguments: String)] {
        guard let array = jsonArray(from: rawArguments) else {
            return []
        }

        return array.compactMap { item in
            guard
                let dictionary = item as? [String: Any],
                let function = dictionary["function"] as? [String: Any],
                let name = function["name"] as? String,
                let arguments = function["arguments"] as? String
            else {
                return nil
            }
            return (name: name, arguments: arguments)
        }
    }

    private static func shortActionPhrase(toolName: String, arguments: String) -> String {
        let args = jsonObject(from: arguments)

        switch toolName {
        case "github_search_paths":
            return "search paths for \"\(stringValue(in: args, key: "query") ?? "query")\""
        case "github_search_code":
            return "search code for \"\(stringValue(in: args, key: "query") ?? "query")\""
        case "github_get_repo_tree":
            return "scan \(stringValue(in: args, key: "path_prefix") ?? "/")"
        case "github_get_file_content":
            return "read \(stringValue(in: args, key: "path") ?? "file")"
        case "github_get_file_lines":
            let path = stringValue(in: args, key: "path") ?? "file"
            if let startLine = intValue(in: args, key: "start_line"),
               let endLine = intValue(in: args, key: "end_line") {
                return "read \(path) lines \(startLine)-\(endLine)"
            }
            return "read lines from \(path)"
        case "github_get_file_tail":
            return "read the tail of \(stringValue(in: args, key: "path") ?? "file")"
        case "github_commit_file_changes":
            let pathSummary = formatPathList(changedPaths(from: args), maxCount: 2) ?? "files"
            return "prepare changes for \(pathSummary)"
        default:
            return title(for: toolName, fallback: toolName).lowercased()
        }
    }

    private static func changedPaths(from args: [String: Any]?) -> [String] {
        dictArray(in: args, key: "changes").compactMap { stringValue(in: $0, key: "path") }
    }

    private static func matchCountSummary(returnedCount: Int?, totalCount: Int?) -> String {
        switch (returnedCount, totalCount) {
        case let (returnedCount?, totalCount?):
            return "Found \(returnedCount) of \(totalCount) matches."
        case let (returnedCount?, nil):
            return "Found \(returnedCount) matches."
        default:
            return "Finished the search."
        }
    }

    private static func codeCountSummary(returnedCount: Int?, searchedFiles: Int?) -> String {
        switch (returnedCount, searchedFiles) {
        case let (returnedCount?, searchedFiles?):
            return "Returned \(returnedCount) result\(returnedCount == 1 ? "" : "s") after scanning \(searchedFiles) file\(searchedFiles == 1 ? "" : "s")."
        case let (returnedCount?, nil):
            return "Returned \(returnedCount) result\(returnedCount == 1 ? "" : "s")."
        default:
            return "Finished the code search."
        }
    }

    private static func formatPathList(_ paths: [String], maxCount: Int) -> String? {
        let trimmedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedPaths.isEmpty else {
            return nil
        }

        let uniquePaths = Array(NSOrderedSet(array: trimmedPaths)) as? [String] ?? trimmedPaths
        let shown = uniquePaths.prefix(maxCount)
        let remainingCount = max(uniquePaths.count - shown.count, 0)
        let joined = shown.joined(separator: ", ")
        return remainingCount > 0 ? "\(joined) +\(remainingCount) more" : joined
    }

    private static func prettyPrintedJSON(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        guard
            let data = rawValue.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return rawValue
        }

        return prettyString
    }

    private static func jsonObject(from rawValue: String?) -> [String: Any]? {
        guard
            let rawValue,
            let data = rawValue.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        return dictionary
    }

    private static func jsonArray(from rawValue: String?) -> [Any]? {
        guard
            let rawValue,
            let data = rawValue.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let array = object as? [Any]
        else {
            return nil
        }

        return array
    }

    private static func dictArray(in dictionary: [String: Any]?, key: String) -> [[String: Any]] {
        (dictionary?[key] as? [[String: Any]]) ?? []
    }

    private static func stringArray(in dictionary: [String: Any]?, key: String) -> [String]? {
        if let strings = dictionary?[key] as? [String] {
            return strings
        }
        return nil
    }

    private static func stringValue(in dictionary: [String: Any]?, key: String) -> String? {
        if let value = dictionary?[key] as? String {
            return value
        }
        return nil
    }

    private static func intValue(in dictionary: [String: Any]?, key: String) -> Int? {
        if let value = dictionary?[key] as? Int {
            return value
        }
        if let value = dictionary?[key] as? NSNumber {
            return value.intValue
        }
        if let value = dictionary?[key] as? String, let intValue = Int(value) {
            return intValue
        }
        return nil
    }

    private static func boolValue(in dictionary: [String: Any]?, key: String) -> Bool? {
        if let value = dictionary?[key] as? Bool {
            return value
        }
        if let value = dictionary?[key] as? String {
            switch value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
