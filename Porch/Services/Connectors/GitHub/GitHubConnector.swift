import Foundation

final class GitHubConnector: Connector, @unchecked Sendable {
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
        case "github_create_branch_and_commit_changes":
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
        case "github_create_branch_and_commit_changes":
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

        let args = try decodeArgs(Args.self, from: Data(arguments.utf8))
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

        let args = try decodeArgs(Args.self, from: Data(arguments.utf8))
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

    private func decodeArgs<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConnectorError.invalidArguments(error.localizedDescription)
        }
    }

    private func encodeResult<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
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
            description: "List files and directories in a GitHub repository path. Use to browse the file tree.",
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
            description: "List files and directories in the currently selected GitHub repository and branch. Use to browse the file tree.",
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
            name: "github_create_branch_and_commit_changes",
            description: "Prepare a new GitHub branch and one commit containing text file create, update, or delete changes. Requires explicit user approval before any write occurs.",
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
                    "base_ref": .object([
                        "type": .string("string"),
                        "description": .string("Optional base branch name. Defaults to main, then the repository default branch.")
                    ]),
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
                        "description": .string("Up to 20 text file changes to create, update, or delete."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object([
                                    "type": .string("string"),
                                    "description": .string("Repository-relative file path")
                                ]),
                                "operation": .object([
                                    "type": .string("string"),
                                    "description": .string("One of: create, update, delete")
                                ]),
                                "content": .object([
                                    "type": .string("string"),
                                    "description": .string("Required for create/update. Must be omitted for delete.")
                                ])
                            ]),
                            "required": .array([
                                .string("path"),
                                .string("operation")
                            ])
                        ])
                    ])
                ]),
                "required": .array([
                    .string("owner"),
                    .string("repo"),
                    .string("commit_message"),
                    .string("changes")
                ])
            ])
        ))
    }

    private var createBranchAndCommitChangesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_create_branch_and_commit_changes",
            description: "Prepare a new branch from the currently selected GitHub base branch and one commit containing text file create, update, or delete changes. Requires explicit user approval before any write occurs.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
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
                        "description": .string("Up to 20 text file changes to create, update, or delete."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object([
                                    "type": .string("string"),
                                    "description": .string("Repository-relative file path")
                                ]),
                                "operation": .object([
                                    "type": .string("string"),
                                    "description": .string("One of: create, update, delete")
                                ]),
                                "content": .object([
                                    "type": .string("string"),
                                    "description": .string("Required for create/update. Must be omitted for delete.")
                                ])
                            ]),
                            "required": .array([
                                .string("path"),
                                .string("operation")
                            ])
                        ])
                    ])
                ]),
                "required": .array([
                    .string("commit_message"),
                    .string("changes")
                ])
            ])
        ))
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
