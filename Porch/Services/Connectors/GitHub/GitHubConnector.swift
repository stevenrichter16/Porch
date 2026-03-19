import Foundation

final class GitHubConnector: Connector, @unchecked Sendable {
    private enum GitHubWriteArgumentsMode: Equatable {
        case freeform
        case selectedContext

        static let repoIdentityKeys: Set<String> = ["owner", "repo", "base_ref"]
        static let changeFieldKeys: Set<String> = ["path", "operation", "content"]

        var allowedTopLevelKeys: Set<String> {
            switch self {
            case .freeform:
                return Self.repoIdentityKeys.union(["branch_name", "commit_message", "changes"])
            case .selectedContext:
                return ["branch_name", "commit_message", "changes"]
            }
        }
    }

    let id = "github"
    let displayName = "GitHub"
    let iconSystemName = "chevron.left.forwardslash.chevron.right"

    private static let maxFileOperations = 20
    private static let maxFileContentBytes = 100_000
    private static let maxTotalContentBytes = 300_000
    private static let maxDiffPreviewCharacters = 12_000

    private let keychain: KeychainStoreProtocol
    private let keychainAccount = "github-pat"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date

    init(
        keychain: KeychainStoreProtocol = KeychainStore(),
        session: URLSession = .shared,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.session = session
        self.nowProvider = nowProvider
    }

    var isConfigured: Bool {
        guard let token = try? keychain.read(account: keychainAccount) else { return false }
        return !token.isEmpty
    }

    // MARK: - Tool Definitions

    var toolDefinitions: [ToolDefinition] {
        [
            searchReposTool,
            getRepoContentsTool,
            getFileContentTool,
            listIssuesTool,
            getIssueTool,
            listPullRequestsTool,
            getPullRequestTool,
            createBranchAndCommitChangesTool
        ]
    }

    func isWriteTool(_ toolName: String) -> Bool {
        toolName == createBranchAndCommitChangesTool.function.name
    }

    func toolDefinitions(for chatContext: GitHubChatContext?) -> [ToolDefinition] {
        guard chatContext != nil else {
            return []
        }

        return [
            getRepoContentsToolForSelectedContext,
            getRepoTreeToolForSelectedContext,
            getFileContentToolForSelectedContext,
            listIssuesToolForSelectedContext,
            getIssueToolForSelectedContext,
            listPullRequestsToolForSelectedContext,
            getPullRequestToolForSelectedContext,
            createBranchAndCommitChangesToolForSelectedContext
        ]
    }

    // MARK: - Execution

    func execute(toolName: String, arguments: String) async throws -> String {
        let client = try makeClient()
        let argsData = Data(arguments.utf8)

        switch toolName {
        case "github_search_repos":
            return try await executeSearchRepos(client: client, argsData: argsData)
        case "github_get_repo_contents":
            return try await executeGetRepoContents(client: client, argsData: argsData)
        case "github_get_file_content":
            return try await executeGetFileContent(client: client, argsData: argsData)
        case "github_list_issues":
            return try await executeListIssues(client: client, argsData: argsData)
        case "github_get_issue":
            return try await executeGetIssue(client: client, argsData: argsData)
        case "github_list_pull_requests":
            return try await executeListPullRequests(client: client, argsData: argsData)
        case "github_get_pull_request":
            return try await executeGetPullRequest(client: client, argsData: argsData)
        case "github_commit_file_changes":
            throw ConnectorError.apiError("GitHub write tools require explicit approval before execution.")
        default:
            throw ConnectorError.unknownTool(toolName)
        }
    }

    func execute(
        toolName: String,
        arguments: String,
        context: GitHubChatContext
    ) async throws -> String {
        let client = try makeClient()
        let argsData = Data(arguments.utf8)

        switch toolName {
        case "github_get_repo_contents":
            return try await executeGetRepoContents(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                argsData: argsData
            )
        case "github_get_repo_tree":
            return try await executeGetRepoTree(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData
            )
        case "github_get_file_content":
            return try await executeGetFileContent(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                argsData: argsData
            )
        case "github_list_issues":
            return try await executeListIssues(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            )
        case "github_get_issue":
            return try await executeGetIssue(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            )
        case "github_list_pull_requests":
            return try await executeListPullRequests(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            )
        case "github_get_pull_request":
            return try await executeGetPullRequest(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            )
        case "github_commit_file_changes":
            throw ConnectorError.apiError("GitHub write tools require explicit approval before execution.")
        default:
            throw ConnectorError.unknownTool(toolName)
        }
    }

    func prepareWriteRequest(toolName: String, arguments: String) async throws -> GitHubWriteRequest {
        guard isWriteTool(toolName) else {
            throw ConnectorError.unknownTool(toolName)
        }

        struct Args: Decodable {
            var owner: String
            var repo: String
            var base_ref: String?
            var branch_name: String?
            var commit_message: String
            var changes: [GitHubFileChange]
        }

        let argsData = try validateGitHubWriteArguments(arguments, mode: .freeform)
        let args = try decodeArgs(
            Args.self,
            from: argsData,
            example: gitHubWriteArgumentsExample(for: .freeform)
        )
        return try await prepareWriteRequest(
            owner: args.owner,
            repo: args.repo,
            requestedBaseRef: args.base_ref,
            requestedBranchName: args.branch_name,
            commitMessage: args.commit_message,
            changes: args.changes
        )
    }

    func prepareWriteRequest(
        toolName: String,
        arguments: String,
        context: GitHubChatContext
    ) async throws -> GitHubWriteRequest {
        guard isWriteTool(toolName) else {
            throw ConnectorError.unknownTool(toolName)
        }

        struct Args: Decodable {
            var branch_name: String?
            var commit_message: String
            var changes: [GitHubFileChange]
        }

        let argsData = try validateGitHubWriteArguments(arguments, mode: .selectedContext)
        let args = try decodeArgs(
            Args.self,
            from: argsData,
            example: gitHubWriteArgumentsExample(for: .selectedContext)
        )
        return try await prepareWriteRequest(
            owner: context.owner,
            repo: context.repo,
            requestedBaseRef: context.branch,
            requestedBranchName: args.branch_name,
            commitMessage: args.commit_message,
            changes: args.changes
        )
    }

    func executeApprovedWrite(
        _ request: GitHubWriteRequest,
        branchName: String,
        commitMessage: String
    ) async throws -> GitHubWriteResult {
        guard let token = try keychain.read(account: keychainAccount), !token.isEmpty else {
            throw ConnectorError.notConfigured("GitHub")
        }

        let normalizedBranchName = try validateBranchName(branchName)
        let trimmedCommitMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommitMessage.isEmpty else {
            throw ConnectorError.invalidArguments("Commit message cannot be empty.")
        }

        let client = GitHubAPIClient(token: token, session: session)
        try await ensureBranchDoesNotExist(
            owner: request.owner,
            repo: request.repo,
            branchName: normalizedBranchName,
            client: client
        )

        var treeEntries: [GitHubCreateTreeRequest.Entry] = []
        treeEntries.reserveCapacity(request.changes.count)

        for change in request.changes {
            switch change.operation {
            case .create, .update:
                let blob = try await client.createBlob(
                    owner: request.owner,
                    repo: request.repo,
                    content: change.content ?? ""
                )
                treeEntries.append(GitHubCreateTreeRequest.Entry(path: change.path, sha: blob.sha))

            case .delete:
                treeEntries.append(
                    GitHubCreateTreeRequest.Entry(path: change.path, sha: nil, isDelete: true)
                )
            }
        }

        let createdTree = try await client.createTree(
            owner: request.owner,
            repo: request.repo,
            requestBody: GitHubCreateTreeRequest(base_tree: request.baseTreeSHA, tree: treeEntries)
        )
        let createdCommit = try await client.createCommit(
            owner: request.owner,
            repo: request.repo,
            message: trimmedCommitMessage,
            treeSHA: createdTree.sha,
            parentCommitSHA: request.baseCommitSHA
        )
        _ = try await client.createRef(
            owner: request.owner,
            repo: request.repo,
            branchName: normalizedBranchName,
            commitSHA: createdCommit.sha
        )

        let createdCount = request.changes.filter { $0.operation == .create }.count
        let updatedCount = request.changes.filter { $0.operation == .update }.count
        let deletedCount = request.changes.filter { $0.operation == .delete }.count

        return GitHubWriteResult(
            status: "success",
            owner: request.owner,
            repo: request.repo,
            base_ref: request.resolvedBaseRef,
            branch_name: normalizedBranchName,
            branch_ref: "refs/heads/\(normalizedBranchName)",
            branch_url: request.repositoryHTMLURL + "/tree/\(normalizedBranchName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedBranchName)",
            commit_message: trimmedCommitMessage,
            commit_sha: createdCommit.sha,
            commit_url: createdCommit.html_url,
            changed_files: request.changes.count,
            created_count: createdCount,
            updated_count: updatedCount,
            deleted_count: deletedCount
        )
    }

    // MARK: - Tool Implementations

    private func executeSearchRepos(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct SearchRepositoriesResult: Encodable {
            let total_count: Int
            let repositories: [[String: String]]
        }

        struct Args: Decodable { var query: String; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let response = try await client.searchRepositories(query: args.query, perPage: args.per_page ?? 10)
        let result: [[String: String]] = response.items.map(\.summary)
        return try encodeResult(
            SearchRepositoriesResult(
                total_count: response.total_count,
                repositories: result
            )
        )
    }

    private func executeGetRepoContents(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var path: String?; var ref: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let items = try await client.getRepoContents(owner: args.owner, repo: args.repo, path: args.path ?? "", ref: args.ref)
        let result: [[String: String]] = items.map(\.summary)
        return try encodeResult(["items": result])
    }

    private func executeGetRepoContents(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var path: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let items = try await client.getRepoContents(owner: owner, repo: repo, path: args.path ?? "", ref: ref)
        let result: [[String: String]] = items.map(\.summary)
        return try encodeResult(["items": result])
    }

    private func executeGetRepoTree(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable {
            var path_prefix: String?
            var entry_type: String?
            var max_entries: Int?
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let pathPrefix = try normalizeTreePathPrefix(args.path_prefix)
        let entryFilter = try parseTreeEntryFilter(args.entry_type)
        let maxEntries = try validateMaxTreeEntries(args.max_entries)

        let tree = try await client.getRecursiveTree(owner: owner, repo: repo, refName: ref)
        let matchingEntries = tree.tree
            .compactMap { makeRepoTreeEntry(from: $0) }
            .filter { entry in
                matchesTreePrefix(entry.path, pathPrefix: pathPrefix) &&
                matchesTreeEntryFilter(entry.kind, filter: entryFilter)
            }
            .sorted { $0.path < $1.path }

        let limitedEntries = Array(matchingEntries.prefix(maxEntries))
        let result = GitHubRepoTreeResult(
            repository: repositoryFullName,
            branch: ref,
            path_prefix: pathPrefix,
            returned_count: limitedEntries.count,
            total_matching_count: matchingEntries.count,
            truncated: tree.truncated == true || matchingEntries.count > limitedEntries.count,
            entries: limitedEntries
        )
        return try encodeResult(result)
    }

    private func executeGetFileContent(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var path: String; var ref: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let file = try await client.getFileContent(owner: args.owner, repo: args.repo, path: args.path, ref: args.ref)
        var result: [String: String] = [
            "name": file.name,
            "path": file.path,
            "size": "\(file.size)"
        ]
        if let decoded = file.decodedContent {
            if decoded.count > 50_000 {
                result["content"] = String(decoded.prefix(50_000)) + "\n\n[Content truncated at 50,000 characters]"
                result["truncated"] = "true"
            } else {
                result["content"] = decoded
            }
        }
        return try encodeResult(result)
    }

    private func executeGetFileContent(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var path: String }
        let args = try decodeArgs(Args.self, from: argsData)
        let file = try await client.getFileContent(owner: owner, repo: repo, path: args.path, ref: ref)
        var result: [String: String] = [
            "name": file.name,
            "path": file.path,
            "size": "\(file.size)"
        ]
        if let decoded = file.decodedContent {
            if decoded.count > 50_000 {
                result["content"] = String(decoded.prefix(50_000)) + "\n\n[Content truncated at 50,000 characters]"
                result["truncated"] = "true"
            } else {
                result["content"] = decoded
            }
        }
        return try encodeResult(result)
    }

    private func executeListIssues(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var state: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let issues = try await client.listIssues(
            owner: args.owner,
            repo: args.repo,
            state: args.state ?? "open",
            perPage: args.per_page ?? 10
        )
        let filtered = issues.filter { !$0.isPullRequest }
        let result: [[String: String]] = filtered.map(\.summary)
        return try encodeResult(["issues": result])
    }

    private func executeListIssues(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var state: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let issues = try await client.listIssues(
            owner: owner,
            repo: repo,
            state: args.state ?? "open",
            perPage: args.per_page ?? 10
        )
        let filtered = issues.filter { !$0.isPullRequest }
        let result: [[String: String]] = filtered.map(\.summary)
        return try encodeResult(["issues": result])
    }

    private func executeGetIssue(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var number: Int }
        let args = try decodeArgs(Args.self, from: argsData)
        let issue = try await client.getIssue(owner: args.owner, repo: args.repo, number: args.number)
        return try encodeResult(issue.summary)
    }

    private func executeGetIssue(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var number: Int }
        let args = try decodeArgs(Args.self, from: argsData)
        let issue = try await client.getIssue(owner: owner, repo: repo, number: args.number)
        return try encodeResult(issue.summary)
    }

    private func executeListPullRequests(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var state: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let prs = try await client.listPullRequests(
            owner: args.owner,
            repo: args.repo,
            state: args.state ?? "open",
            perPage: args.per_page ?? 10
        )
        let result: [[String: String]] = prs.map(\.summary)
        return try encodeResult(["pull_requests": result])
    }

    private func executeListPullRequests(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var state: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let prs = try await client.listPullRequests(
            owner: owner,
            repo: repo,
            state: args.state ?? "open",
            perPage: args.per_page ?? 10
        )
        let result: [[String: String]] = prs.map(\.summary)
        return try encodeResult(["pull_requests": result])
    }

    private func executeGetPullRequest(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var number: Int }
        let args = try decodeArgs(Args.self, from: argsData)
        let pr = try await client.getPullRequest(owner: args.owner, repo: args.repo, number: args.number)
        return try encodeResult(pr.summary)
    }

    private func executeGetPullRequest(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var number: Int }
        let args = try decodeArgs(Args.self, from: argsData)
        let pr = try await client.getPullRequest(owner: owner, repo: repo, number: args.number)
        return try encodeResult(pr.summary)
    }

    // MARK: - Helpers

    private func makeClient() throws -> GitHubAPIClient {
        guard let token = try keychain.read(account: keychainAccount), !token.isEmpty else {
            throw ConnectorError.notConfigured("GitHub")
        }

        return GitHubAPIClient(token: token, session: session)
    }

    private func decodeArgs<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        example: String? = nil
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            throw ConnectorError.invalidArguments(
                appendExampleIfNeeded(formatDecodingError(decodingError), example: example)
            )
        } catch {
            throw ConnectorError.invalidArguments(
                appendExampleIfNeeded(error.localizedDescription, example: example)
            )
        }
    }

    private func encodeResult<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func validateGitHubWriteArguments(
        _ arguments: String,
        mode: GitHubWriteArgumentsMode
    ) throws -> Data {
        let data = Data(arguments.utf8)
        let jsonObject: Any

        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw gitHubWriteValidationError(
                "Arguments must be valid JSON. Ensure embedded file contents are JSON-escaped strings, with \\n for newlines and \\\" for quotes.",
                mode: mode
            )
        }

        guard let object = jsonObject as? [String: Any] else {
            throw gitHubWriteValidationError("Arguments must be a JSON object.", mode: mode)
        }

        let allowedTopLevelKeys = mode.allowedTopLevelKeys
        let unexpectedTopLevelKeys = Set(object.keys).subtracting(allowedTopLevelKeys)
        if !unexpectedTopLevelKeys.isEmpty {
            let sortedUnexpectedKeys = unexpectedTopLevelKeys.sorted()
            if mode == .selectedContext && sortedUnexpectedKeys.contains(where: { GitHubWriteArgumentsMode.repoIdentityKeys.contains($0) }) {
                throw gitHubWriteValidationError(
                    "Do not send owner, repo, or base_ref in this chat-scoped tool call. The selected GitHub repository and base branch are already known for this chat.",
                    mode: mode
                )
            }
            if sortedUnexpectedKeys.contains(where: { GitHubWriteArgumentsMode.changeFieldKeys.contains($0) }) {
                throw gitHubWriteValidationError(
                    "Do not place path, operation, or content at the top level. Each file change must be an object inside changes[].",
                    mode: mode
                )
            }
            throw gitHubWriteValidationError(
                "Unexpected top-level keys: \(sortedUnexpectedKeys.joined(separator: ", ")).",
                mode: mode
            )
        }

        guard let changes = object["changes"] else {
            throw gitHubWriteValidationError("Missing required key 'changes'.", mode: mode)
        }
        guard let changesArray = changes as? [Any] else {
            throw gitHubWriteValidationError("changes must be an array of file change objects.", mode: mode)
        }
        guard !changesArray.isEmpty else {
            throw gitHubWriteValidationError("changes must contain at least one file change object.", mode: mode)
        }

        for (index, rawChange) in changesArray.enumerated() {
            guard let change = rawChange as? [String: Any] else {
                throw gitHubWriteValidationError(
                    "changes[\(index)] must be an object with path, operation, and optional content.",
                    mode: mode
                )
            }

            let unexpectedChangeKeys = Set(change.keys).subtracting(GitHubWriteArgumentsMode.changeFieldKeys)
            if !unexpectedChangeKeys.isEmpty {
                throw gitHubWriteValidationError(
                    "Unexpected keys in changes[\(index)]: \(unexpectedChangeKeys.sorted().joined(separator: ", ")). Allowed keys are path, operation, and content.",
                    mode: mode
                )
            }

            guard let operation = change["operation"] else { continue }
            guard let operationString = operation as? String else {
                throw gitHubWriteValidationError(
                    "changes[\(index)].operation must be one of create, update, or delete.",
                    mode: mode
                )
            }
            guard GitHubFileOperation(rawValue: operationString) != nil else {
                throw gitHubWriteValidationError(
                    "changes[\(index)].operation must be one of create, update, or delete.",
                    mode: mode
                )
            }
        }

        return data
    }

    private func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing required key '\(key.stringValue)' at \(codingPathDescription(context.codingPath))."
        case .typeMismatch(let type, let context):
            return "Expected \(String(describing: type)) at \(codingPathDescription(context.codingPath)). \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Missing \(String(describing: type)) value at \(codingPathDescription(context.codingPath)). \(context.debugDescription)"
        case .dataCorrupted(let context):
            let baseMessage = "Arguments contain invalid JSON or invalid string escaping at \(codingPathDescription(context.codingPath))."
            guard !context.debugDescription.isEmpty else {
                return baseMessage
            }
            return "\(baseMessage) \(context.debugDescription)"
        @unknown default:
            return "Arguments do not match the expected JSON format."
        }
    }

    private func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "root"
        }

        return codingPath.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }
        .joined(separator: ".")
    }

    private func appendExampleIfNeeded(_ message: String, example: String?) -> String {
        guard let example else { return message }
        return "\(message) Example: \(example)"
    }

    private func gitHubWriteValidationError(
        _ message: String,
        mode: GitHubWriteArgumentsMode
    ) -> ConnectorError {
        .invalidArguments(appendExampleIfNeeded(message, example: gitHubWriteArgumentsExample(for: mode)))
    }

    private func prepareWriteRequest(
        owner: String,
        repo: String,
        requestedBaseRef: String?,
        requestedBranchName: String?,
        commitMessage: String,
        changes: [GitHubFileChange]
    ) async throws -> GitHubWriteRequest {
        let trimmedCommitMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommitMessage.isEmpty else {
            throw ConnectorError.invalidArguments("commit_message is required.")
        }

        let normalizedChanges = try normalizeChanges(changes)
        let client = try makeClient()
        let repository = try await client.getRepository(owner: owner, repo: repo)
        let baseResolution = try await resolveBaseRef(
            requestedBaseRef: requestedBaseRef,
            owner: owner,
            repo: repo,
            repository: repository,
            client: client
        )

        let proposedBranchName = try resolveProposedBranchName(
            requestedBranchName: requestedBranchName,
            commitMessage: trimmedCommitMessage
        )
        try await ensureBranchDoesNotExist(
            owner: owner,
            repo: repo,
            branchName: proposedBranchName,
            client: client
        )

        let baseCommit = try await client.getCommit(
            owner: owner,
            repo: repo,
            sha: baseResolution.ref.object.sha
        )
        let tree = try await client.getTree(
            owner: owner,
            repo: repo,
            sha: baseCommit.tree.sha,
            recursive: true
        )

        guard tree.truncated != true else {
            throw ConnectorError.apiError("This repository tree is too large to validate safely.")
        }

        let treeByPath = Dictionary(uniqueKeysWithValues: tree.tree.compactMap { entry in
            entry.path.isEmpty ? nil : (entry.path, entry)
        })

        var diffPreviews: [GitHubDiffPreview] = []
        for change in normalizedChanges {
            let existingEntry = treeByPath[change.path]
            switch change.operation {
            case .create:
                guard existingEntry == nil else {
                    throw ConnectorError.invalidArguments("Cannot create \(change.path) because it already exists.")
                }
                diffPreviews.append(
                    GitHubDiffPreview(
                        path: change.path,
                        operation: .create,
                        diffText: renderDiffPreview(
                            operation: .create,
                            existingContent: nil,
                            newContent: change.content ?? ""
                        )
                    )
                )

            case .update:
                guard let existingEntry else {
                    throw ConnectorError.invalidArguments("Cannot update \(change.path) because it does not exist.")
                }
                guard existingEntry.type == "blob" else {
                    throw ConnectorError.invalidArguments("Can only update files, not directories: \(change.path)")
                }
                let currentContent = try await fetchTextFileContent(
                    owner: owner,
                    repo: repo,
                    path: change.path,
                    ref: baseResolution.name,
                    client: client
                )
                if currentContent == (change.content ?? "") {
                    throw ConnectorError.invalidArguments("No content change was proposed for \(change.path).")
                }
                diffPreviews.append(
                    GitHubDiffPreview(
                        path: change.path,
                        operation: .update,
                        diffText: renderDiffPreview(
                            operation: .update,
                            existingContent: currentContent,
                            newContent: change.content ?? ""
                        )
                    )
                )

            case .delete:
                guard let existingEntry else {
                    throw ConnectorError.invalidArguments("Cannot delete \(change.path) because it does not exist.")
                }
                guard existingEntry.type == "blob" else {
                    throw ConnectorError.invalidArguments("Can only delete files, not directories: \(change.path)")
                }
                let currentContent = try await fetchTextFileContent(
                    owner: owner,
                    repo: repo,
                    path: change.path,
                    ref: baseResolution.name,
                    client: client
                )
                diffPreviews.append(
                    GitHubDiffPreview(
                        path: change.path,
                        operation: .delete,
                        diffText: renderDiffPreview(
                            operation: .delete,
                            existingContent: currentContent,
                            newContent: nil
                        )
                    )
                )
            }
        }

        return GitHubWriteRequest(
            owner: owner,
            repo: repo,
            repositoryFullName: repository.full_name,
            repositoryHTMLURL: repository.html_url,
            resolvedBaseRef: baseResolution.name,
            proposedBranchName: proposedBranchName,
            commitMessage: trimmedCommitMessage,
            baseCommitSHA: baseCommit.sha,
            baseTreeSHA: baseCommit.tree.sha,
            changes: normalizedChanges,
            diffPreviews: diffPreviews
        )
    }

    private func normalizeChanges(_ changes: [GitHubFileChange]) throws -> [GitHubFileChange] {
        guard !changes.isEmpty else {
            throw ConnectorError.invalidArguments("At least one file change is required.")
        }
        guard changes.count <= Self.maxFileOperations else {
            throw ConnectorError.invalidArguments("At most \(Self.maxFileOperations) file changes are allowed.")
        }

        var normalizedChanges: [GitHubFileChange] = []
        normalizedChanges.reserveCapacity(changes.count)
        var seenPaths = Set<String>()
        var totalContentBytes = 0

        for change in changes {
            let normalizedPath = try normalizeRepoPath(change.path)
            guard seenPaths.insert(normalizedPath).inserted else {
                throw ConnectorError.invalidArguments("Duplicate change path: \(normalizedPath)")
            }

            let normalizedContent: String?
            switch change.operation {
            case .create, .update:
                guard let content = change.content else {
                    throw ConnectorError.invalidArguments("content is required for \(change.operation.rawValue) on \(normalizedPath).")
                }
                let byteCount = content.lengthOfBytes(using: .utf8)
                guard byteCount <= Self.maxFileContentBytes else {
                    throw ConnectorError.invalidArguments("File \(normalizedPath) exceeds the 100 KB limit.")
                }
                totalContentBytes += byteCount
                normalizedContent = content

            case .delete:
                guard change.content == nil else {
                    throw ConnectorError.invalidArguments("content must not be provided for delete on \(normalizedPath).")
                }
                normalizedContent = nil
            }

            normalizedChanges.append(
                GitHubFileChange(
                    path: normalizedPath,
                    operation: change.operation,
                    content: normalizedContent
                )
            )
        }

        guard totalContentBytes <= Self.maxTotalContentBytes else {
            throw ConnectorError.invalidArguments("Total proposed content exceeds the 300 KB limit.")
        }

        return normalizedChanges
    }

    private func normalizeRepoPath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectorError.invalidArguments("File paths must not be empty.")
        }
        guard !trimmed.hasPrefix("/") else {
            throw ConnectorError.invalidArguments("Paths must be repository-relative: \(rawPath)")
        }

        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else {
            throw ConnectorError.invalidArguments("File paths must not be empty.")
        }
        guard !components.contains(".") else {
            throw ConnectorError.invalidArguments("Paths must not contain '.' segments: \(rawPath)")
        }
        guard !components.contains("..") else {
            throw ConnectorError.invalidArguments("Paths must not contain '..' segments: \(rawPath)")
        }
        guard !components.contains(".git") else {
            throw ConnectorError.invalidArguments("Paths must not target git internals: \(rawPath)")
        }

        return components.joined(separator: "/")
    }

    private func normalizeTreePathPrefix(_ rawPrefix: String?) throws -> String? {
        guard let rawPrefix else { return nil }

        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }

        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else {
            return nil
        }
        guard !components.contains(".") else {
            throw ConnectorError.invalidArguments("path_prefix must not contain '.' segments.")
        }
        guard !components.contains("..") else {
            throw ConnectorError.invalidArguments("path_prefix must not contain '..' segments.")
        }
        guard !components.contains(".git") else {
            throw ConnectorError.invalidArguments("path_prefix must not target git internals.")
        }

        return components.joined(separator: "/")
    }

    private enum RepoTreeEntryFilter: String {
        case all
        case files
        case directories
    }

    private func parseTreeEntryFilter(_ rawValue: String?) throws -> RepoTreeEntryFilter {
        guard let rawValue else { return .all }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let filter = RepoTreeEntryFilter(rawValue: normalized) else {
            throw ConnectorError.invalidArguments("entry_type must be one of: all, files, directories.")
        }
        return filter
    }

    private func validateMaxTreeEntries(_ rawValue: Int?) throws -> Int {
        let resolved = rawValue ?? 400
        guard resolved > 0 else {
            throw ConnectorError.invalidArguments("max_entries must be greater than 0.")
        }
        guard resolved <= 1_000 else {
            throw ConnectorError.invalidArguments("max_entries must be 1000 or less.")
        }
        return resolved
    }

    private func makeRepoTreeEntry(from entry: GitHubTreeResponse.Entry) -> GitHubRepoTreeEntry? {
        guard !entry.path.isEmpty else { return nil }
        guard let kind = mapRepoTreeEntryKind(for: entry) else { return nil }
        return GitHubRepoTreeEntry(path: entry.path, kind: kind, size: entry.size)
    }

    private func mapRepoTreeEntryKind(for entry: GitHubTreeResponse.Entry) -> GitHubRepoTreeEntryKind? {
        switch entry.mode {
        case "040000":
            return .directory
        case "100644", "100755":
            return .file
        case "120000":
            return .symlink
        case "160000":
            return .submodule
        default:
            break
        }

        switch entry.type {
        case "tree":
            return .directory
        case "blob":
            return .file
        case "commit":
            return .submodule
        default:
            return nil
        }
    }

    private func matchesTreePrefix(_ path: String, pathPrefix: String?) -> Bool {
        guard let pathPrefix else { return true }
        return path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }

    private func matchesTreeEntryFilter(_ kind: GitHubRepoTreeEntryKind, filter: RepoTreeEntryFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .files:
            return kind == .file
        case .directories:
            return kind == .directory
        }
    }

    private func resolveBaseRef(
        requestedBaseRef: String?,
        owner: String,
        repo: String,
        repository: GitHubRepositoryMetadata,
        client: GitHubAPIClient
    ) async throws -> (name: String, ref: GitHubRef) {
        if let requestedBaseRef, !requestedBaseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = try normalizeRefName(requestedBaseRef)
            let ref = try await client.getRef(owner: owner, repo: repo, ref: "heads/\(normalized)")
            return (normalized, ref)
        }

        do {
            let ref = try await client.getRef(owner: owner, repo: repo, ref: "heads/main")
            return ("main", ref)
        } catch let error as GitHubAPIError where error.statusCode == 404 {
            let fallback = repository.default_branch
            let ref = try await client.getRef(owner: owner, repo: repo, ref: "heads/\(fallback)")
            return (fallback, ref)
        }
    }

    private func resolveProposedBranchName(requestedBranchName: String?, commitMessage: String) throws -> String {
        if let requestedBranchName, !requestedBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try validateBranchName(requestedBranchName)
        }

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: nowProvider())
        let slug = slugify(commitMessage)
        return "porch/\(slug)-\(timestamp)"
    }

    private func normalizeRefName(_ rawRef: String) throws -> String {
        let trimmed = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectorError.invalidArguments("base_ref must not be empty.")
        }
        if let stripped = trimmed.stripPrefix("refs/heads/") {
            return try validateBranchName(stripped)
        }
        if let stripped = trimmed.stripPrefix("heads/") {
            return try validateBranchName(stripped)
        }
        return try validateBranchName(trimmed)
    }

    private func validateBranchName(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectorError.invalidArguments("branch_name must not be empty.")
        }
        guard !trimmed.hasPrefix("/") else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }
        guard !trimmed.hasSuffix("/") else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }
        guard !trimmed.hasSuffix(".lock") else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }
        guard !trimmed.contains(".."),
              !trimmed.contains("@{"),
              !trimmed.contains("\\"),
              !trimmed.contains("^"),
              !trimmed.contains("~"),
              !trimmed.contains(":"),
              !trimmed.contains("?"),
              !trimmed.contains("*"),
              !trimmed.contains("["),
              !trimmed.contains(" "),
              !trimmed.contains("//")
        else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }
        guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") }) else {
            throw ConnectorError.invalidArguments("Invalid branch name: \(rawName)")
        }

        return trimmed
    }

    private func ensureBranchDoesNotExist(
        owner: String,
        repo: String,
        branchName: String,
        client: GitHubAPIClient
    ) async throws {
        do {
            _ = try await client.getRef(owner: owner, repo: repo, ref: "heads/\(branchName)")
            throw ConnectorError.invalidArguments("Branch '\(branchName)' already exists. Choose a different branch name.")
        } catch let error as GitHubAPIError where error.statusCode == 404 {
            return
        }
    }

    private func fetchTextFileContent(
        owner: String,
        repo: String,
        path: String,
        ref: String,
        client: GitHubAPIClient
    ) async throws -> String {
        let file = try await client.getFileContent(owner: owner, repo: repo, path: path, ref: ref)
        guard let decoded = file.decodedContent else {
            throw ConnectorError.invalidArguments("Only UTF-8 text files are supported for write previews: \(path)")
        }
        return decoded
    }

    private func slugify(_ value: String) -> String {
        let lowercased = value.lowercased()
        let replaced = lowercased.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "change" : String(trimmed.prefix(32))
    }

    private func renderDiffPreview(
        operation: GitHubFileOperation,
        existingContent: String?,
        newContent: String?
    ) -> String {
        let preview: String
        switch operation {
        case .create:
            preview = prefixLines(newContent ?? "", prefix: "+ ")
        case .delete:
            preview = prefixLines(existingContent ?? "", prefix: "- ")
        case .update:
            preview = renderUpdatedDiff(
                oldContent: existingContent ?? "",
                newContent: newContent ?? ""
            )
        }

        if preview.count > Self.maxDiffPreviewCharacters {
            return String(preview.prefix(Self.maxDiffPreviewCharacters)) + "\n\n[Diff preview truncated]"
        }
        return preview
    }

    private func renderUpdatedDiff(oldContent: String, newContent: String) -> String {
        let oldLines = splitLines(oldContent)
        let newLines = splitLines(newContent)

        var prefixCount = 0
        while prefixCount < oldLines.count,
              prefixCount < newLines.count,
              oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        var oldSuffixIndex = oldLines.count - 1
        var newSuffixIndex = newLines.count - 1
        while oldSuffixIndex >= prefixCount,
              newSuffixIndex >= prefixCount,
              oldLines[oldSuffixIndex] == newLines[newSuffixIndex] {
            oldSuffixIndex -= 1
            newSuffixIndex -= 1
        }

        let removedLines = changedLines(in: oldLines, start: prefixCount, endInclusive: oldSuffixIndex)
        let addedLines = changedLines(in: newLines, start: prefixCount, endInclusive: newSuffixIndex)
        let removed = prefixLines(removedLines, prefix: "- ")
        let added = prefixLines(addedLines, prefix: "+ ")

        if removed.isEmpty && added.isEmpty {
            return "[No visible diff]"
        }

        var sections: [String] = []
        if prefixCount > 0 {
            let contextStart = max(0, prefixCount - 2)
            let context = oldLines[contextStart..<prefixCount]
            sections.append(prefixLines(context, prefix: "  "))
        }
        if !removed.isEmpty {
            sections.append(removed)
        }
        if !added.isEmpty {
            sections.append(added)
        }
        if oldSuffixIndex + 1 < oldLines.count {
            let start = min(oldSuffixIndex + 1, oldLines.count)
            let end = min(start + 2, oldLines.count)
            if start < end {
                let context = oldLines[start..<end]
                sections.append(prefixLines(context, prefix: "  "))
            }
        }
        return sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func changedLines(in lines: [String], start: Int, endInclusive: Int) -> ArraySlice<String> {
        guard start < lines.count, endInclusive >= start else {
            return []
        }

        return lines[start...min(endInclusive, lines.count - 1)]
    }

    private func splitLines(_ content: String) -> [String] {
        content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private func prefixLines<S: Sequence>(_ lines: S, prefix: String) -> String where S.Element == String {
        lines.map { prefix + $0 }.joined(separator: "\n")
    }

    private func prefixLines(_ content: String, prefix: String) -> String {
        prefixLines(splitLines(content), prefix: prefix)
    }

    // MARK: - Tool Definitions

    private var gitHubWriteChangeSchema: JSONSchemaValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Repository-relative file path for exactly one file.")
                ]),
                "operation": .object([
                    "type": .string("string"),
                    "enum": .array(GitHubFileOperation.allCases.map { .string($0.rawValue) }),
                    "description": .string("create — add a new file (must not already exist); update — replace an existing file with new content (must already exist; first read it with github_get_file_content, then provide the complete modified file content); delete — remove a file (must exist, omit content).")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Required for create and update. Omit for delete. This must be a JSON-escaped string.")
                ])
            ]),
            "required": .array([
                .string("path"),
                .string("operation")
            ])
        ])
    }

    private func gitHubWriteArgumentsSchema(for mode: GitHubWriteArgumentsMode) -> JSONSchemaValue {
        var properties: [String: JSONSchemaValue] = [
            "branch_name": .object([
                "type": .string("string"),
                "description": .string("Optional branch name. If omitted, Porch generates a new porch/<slug>-<timestamp> branch.")
            ]),
            "commit_message": .object([
                "type": .string("string"),
                "description": .string("Commit message for the one commit that Porch will create.")
            ]),
            "changes": .object([
                "type": .string("array"),
                "description": .string("An array of up to 20 file change objects. Each object represents one file and must contain path and operation."),
                "items": gitHubWriteChangeSchema
            ])
        ]

        var required: [JSONSchemaValue] = [
            .string("commit_message"),
            .string("changes")
        ]

        if mode == .freeform {
            properties["owner"] = .object([
                "type": .string("string"),
                "description": .string("Repository owner.")
            ])
            properties["repo"] = .object([
                "type": .string("string"),
                "description": .string("Repository name.")
            ])
            properties["base_ref"] = .object([
                "type": .string("string"),
                "description": .string("Optional base branch name. Defaults to main, then the repository default branch.")
            ])
            required.insert(.string("owner"), at: 0)
            required.insert(.string("repo"), at: 1)
        }

        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(required),
            "examples": .array([gitHubWriteArgumentsExampleSchema(for: mode)])
        ])
    }

    private func gitHubWriteArgumentsExampleSchema(for mode: GitHubWriteArgumentsMode) -> JSONSchemaValue {
        var example: [String: JSONSchemaValue] = [
            "branch_name": .string("feature/update-config"),
            "commit_message": .string("Update config and add tests"),
            "changes": .array([
                .object([
                    "path": .string("Sources/Config.swift"),
                    "operation": .string("update"),
                    "content": .string("// Updated Config.swift with new settings\nstruct Config {\n    let version = 2\n}\n")
                ]),
                .object([
                    "path": .string("Tests/ConfigTests.swift"),
                    "operation": .string("create"),
                    "content": .string("import XCTest\n@testable import App\n\nfinal class ConfigTests: XCTestCase {\n    func testVersion() {\n        XCTAssertEqual(Config().version, 2)\n    }\n}\n")
                ])
            ])
        ]

        if mode == .freeform {
            example["owner"] = .string("octo")
            example["repo"] = .string("demo")
            example["base_ref"] = .string("main")
        }

        return .object(example)
    }

    private func gitHubWriteArgumentsExample(for mode: GitHubWriteArgumentsMode) -> String {
        switch mode {
        case .freeform:
            return #"{"owner":"octo","repo":"demo","base_ref":"main","branch_name":"feature/update-config","commit_message":"Update config and add tests","changes":[{"path":"Sources/Config.swift","operation":"update","content":"struct Config {\n    let version = 2\n}\n"},{"path":"Tests/ConfigTests.swift","operation":"create","content":"import XCTest\n"}]}"#
        case .selectedContext:
            return #"{"branch_name":"feature/update-config","commit_message":"Update config and add tests","changes":[{"path":"Sources/Config.swift","operation":"update","content":"struct Config {\n    let version = 2\n}\n"},{"path":"Tests/ConfigTests.swift","operation":"create","content":"import XCTest\n"}]}"#
        }
    }

    private var searchReposTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_search_repos",
            description: "Search GitHub repositories by query. Returns repository names, descriptions, stars, and languages.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query (e.g. 'swift http client', 'org:apple language:swift')")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results (max 30, default 10)")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))
    }

    private var getRepoContentsTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_repo_contents",
            description: "List exactly one directory level in a GitHub repository path. This is not recursive. Use github_get_repo_tree first when you need to discover nested paths across the repository, then use this for focused folder browsing.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner (e.g. 'apple')")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name (e.g. 'swift')")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path within the repository (default: root)")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Branch, tag, or commit SHA (default: default branch)")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo")])
            ])
        ))
    }

    private var getRepoContentsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_repo_contents",
            description: "List exactly one directory level in the currently selected GitHub repository and branch. This is not recursive. Use github_get_repo_tree first when you need to discover nested paths, then use this for focused folder browsing.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path within the selected repository (default: root)")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var getRepoTreeToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_repo_tree",
            description: "Recursively list nested paths in the currently selected GitHub repository and branch. Use this first to discover exact repo-relative file paths, then call github_get_file_content for specific files, and only then prepare github_commit_file_changes to create, update, or delete files. You can also call github_get_repo_contents(path: ...) afterward for focused directory browsing.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path_prefix": .object([
                        "type": .string("string"),
                        "description": .string("Optional subtree prefix to narrow results, such as 'Sources' or '.github/workflows'.")
                    ]),
                    "entry_type": .object([
                        "type": .string("string"),
                        "description": .string("Filter results by type: 'all' (default), 'files', or 'directories'.")
                    ]),
                    "max_entries": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of returned entries (default 400, max 1000).")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var getFileContentTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_file_content",
            description: "Read the content of a file from a GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path within the repository")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Branch, tag, or commit SHA (default: default branch)")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo"), .string("path")])
            ])
        ))
    }

    private var getFileContentToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_file_content",
            description: "Read the content of a file from the currently selected GitHub repository and branch.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path within the selected repository")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        ))
    }

    private var listIssuesTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_issues",
            description: "List issues in a GitHub repository. Filters out pull requests.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name")
                    ]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter by state: 'open', 'closed', or 'all' (default: 'open')")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results (max 30, default 10)")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo")])
            ])
        ))
    }

    private var listIssuesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_issues",
            description: "List issues in the currently selected GitHub repository. Filters out pull requests.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter by state: 'open', 'closed', or 'all' (default: 'open')")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results (max 30, default 10)")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var getIssueTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_issue",
            description: "Get details of a specific issue by number from a GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name")
                    ]),
                    "number": .object([
                        "type": .string("integer"),
                        "description": .string("Issue number")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo"), .string("number")])
            ])
        ))
    }

    private var getIssueToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_issue",
            description: "Get details of a specific issue by number from the currently selected GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "number": .object([
                        "type": .string("integer"),
                        "description": .string("Issue number")
                    ])
                ]),
                "required": .array([.string("number")])
            ])
        ))
    }

    private var listPullRequestsTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_pull_requests",
            description: "List pull requests in a GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name")
                    ]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter by state: 'open', 'closed', or 'all' (default: 'open')")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results (max 30, default 10)")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo")])
            ])
        ))
    }

    private var listPullRequestsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_pull_requests",
            description: "List pull requests in the currently selected GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter by state: 'open', 'closed', or 'all' (default: 'open')")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results (max 30, default 10)")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var getPullRequestTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_pull_request",
            description: "Get details of a specific pull request by number from a GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "owner": .object([
                        "type": .string("string"),
                        "description": .string("Repository owner")
                    ]),
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository name")
                    ]),
                    "number": .object([
                        "type": .string("integer"),
                        "description": .string("Pull request number")
                    ])
                ]),
                "required": .array([.string("owner"), .string("repo"), .string("number")])
            ])
        ))
    }

    private var getPullRequestToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_pull_request",
            description: "Get details of a specific pull request by number from the currently selected GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "number": .object([
                        "type": .string("integer"),
                        "description": .string("Pull request number")
                    ])
                ]),
                "required": .array([.string("number")])
            ])
        ))
    }

    private var createBranchAndCommitChangesTool: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_commit_file_changes",
            description: "Commit file changes to a new GitHub branch. Supports three operations per file: 'create' (new file), 'update' (replace an existing file — read it first with github_get_file_content, then provide the complete modified content), and 'delete' (remove a file). This free-form variant requires owner and repo, and optionally base_ref. Each element of changes[] represents one file. Requires explicit user approval before any write occurs.",
            parameters: gitHubWriteArgumentsSchema(for: .freeform)
        ))
    }

    private var createBranchAndCommitChangesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_commit_file_changes",
            description: "Commit file changes to a new branch from the currently selected GitHub base branch. Supports three operations per file: 'create' (new file), 'update' (replace an existing file — read it first with github_get_file_content, then provide the complete modified content), and 'delete' (remove a file). Do not send owner, repo, or base_ref here; the selected repository and base branch are already known for this chat. Put path, operation, and optional content inside each changes[] item, where each item represents one file. Requires explicit user approval before any write occurs.",
            parameters: gitHubWriteArgumentsSchema(for: .selectedContext)
        ))
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
