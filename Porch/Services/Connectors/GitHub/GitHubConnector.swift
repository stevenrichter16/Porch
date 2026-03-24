import Foundation
import OSLog

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
    private static let maxReturnedFileContentCharacters = 12_000
    private static let maxCodeSearchCandidateFiles = 40
    private static let logger = Logger(subsystem: "steven.Porch", category: "GitHubConnector")

    private let keychain: KeychainStoreProtocol
    private let keychainAccount = "github-pat"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private let syncCoordinator: GitHubSyncCoordinator

    struct ExecutionResult {
        var output: String
        var validatedRepository: GitHubIndexedRepository?
    }

    init(
        keychain: KeychainStoreProtocol = KeychainStore(),
        session: URLSession = .shared,
        syncCoordinator: GitHubSyncCoordinator = GitHubSyncCoordinator(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.session = session
        self.syncCoordinator = syncCoordinator
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
            searchPathsToolForSelectedContext,
            searchCodeToolForSelectedContext,
            getRepoContentsToolForSelectedContext,
            getRepoTreeToolForSelectedContext,
            getFileContentToolForSelectedContext,
            getFileLinesToolForSelectedContext,
            getFileTailToolForSelectedContext,
            listBranchesToolForSelectedContext,
            listCommitsToolForSelectedContext,
            compareRefsToolForSelectedContext,
            listIssuesToolForSelectedContext,
            searchIssuesToolForSelectedContext,
            getIssueToolForSelectedContext,
            listPullRequestsToolForSelectedContext,
            searchPullRequestsToolForSelectedContext,
            getPullRequestToolForSelectedContext,
            getPullRequestFilesToolForSelectedContext,
            getPullRequestDiffToolForSelectedContext,
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
        let result = try await executeDetailed(
            toolName: toolName,
            arguments: arguments,
            context: context
        )
        return result.output
    }

    func executeDetailed(
        toolName: String,
        arguments: String,
        context: GitHubChatContext,
        validatedRepository: GitHubIndexedRepository? = nil
    ) async throws -> ExecutionResult {
        let client = try makeClient()
        let argsData = Data(arguments.utf8)

        switch toolName {
        case "github_search_paths":
            return try await executeSearchPaths(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_search_code":
            return try await executeSearchCode(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_get_repo_contents":
            return ExecutionResult(output: try await executeGetRepoContents(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                argsData: argsData
            ))
        case "github_get_repo_tree":
            return try await executeGetRepoTree(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_get_file_content":
            return try await executeGetFileContent(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_get_file_lines":
            return try await executeGetFileLines(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_get_file_tail":
            return try await executeGetFileTail(
                client: client,
                owner: context.owner,
                repo: context.repo,
                ref: context.branch,
                repositoryFullName: context.repositoryLabel,
                argsData: argsData,
                validatedRepository: validatedRepository
            )
        case "github_list_branches":
            return ExecutionResult(output: try await executeListBranches(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_list_commits":
            return ExecutionResult(output: try await executeListCommits(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_compare_refs":
            return ExecutionResult(output: try await executeCompareRefs(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_list_issues":
            return ExecutionResult(output: try await executeListIssues(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_search_issues":
            return ExecutionResult(output: try await executeSearchIssues(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_get_issue":
            return ExecutionResult(output: try await executeGetIssue(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_list_pull_requests":
            return ExecutionResult(output: try await executeListPullRequests(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_search_pull_requests":
            return ExecutionResult(output: try await executeSearchPullRequests(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_get_pull_request":
            return ExecutionResult(output: try await executeGetPullRequest(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_get_pull_request_files":
            return ExecutionResult(output: try await executeGetPullRequestFiles(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
        case "github_get_pull_request_diff":
            return ExecutionResult(output: try await executeGetPullRequestDiff(
                client: client,
                owner: context.owner,
                repo: context.repo,
                argsData: argsData
            ))
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

        do {
            let argsData = try validateGitHubWriteArguments(arguments, mode: .freeform)
            let args = try decodeArgs(
                Args.self,
                from: argsData,
                example: gitHubWriteArgumentsExample(for: .freeform)
            )
            Self.logger.notice("Preparing freeform GitHub write request for \(args.owner, privacy: .public)/\(args.repo, privacy: .public) requestedBase=\(args.base_ref ?? "<auto>", privacy: .public) requestedBranch=\(args.branch_name ?? "<auto>", privacy: .public) changeCount=\(args.changes.count, privacy: .public)")
            Self.logger.debug("GitHub write changes: \(self.summarizeChanges(args.changes), privacy: .public)")
            return try await prepareWriteRequest(
                owner: args.owner,
                repo: args.repo,
                requestedBaseRef: args.base_ref,
                requestedBranchName: args.branch_name,
                commitMessage: args.commit_message,
                changes: args.changes
            )
        } catch {
            Self.logger.error("Failed to prepare freeform GitHub write request: \(error.localizedDescription, privacy: .public)")
            throw error
        }
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

        do {
            let argsData = try validateGitHubWriteArguments(arguments, mode: .selectedContext)
            let args = try decodeArgs(
                Args.self,
                from: argsData,
                example: gitHubWriteArgumentsExample(for: .selectedContext)
            )
            Self.logger.notice("Preparing context-bound GitHub write request for \(context.repositoryLabel, privacy: .public) base=\(context.branch, privacy: .public) requestedBranch=\(args.branch_name ?? "<auto>", privacy: .public) changeCount=\(args.changes.count, privacy: .public)")
            Self.logger.debug("GitHub write changes: \(self.summarizeChanges(args.changes), privacy: .public)")
            return try await prepareWriteRequest(
                owner: context.owner,
                repo: context.repo,
                requestedBaseRef: context.branch,
                requestedBranchName: args.branch_name,
                commitMessage: args.commit_message,
                changes: args.changes
            )
        } catch {
            Self.logger.error("Failed to prepare context-bound GitHub write request for \(context.repositoryLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func executeApprovedWrite(
        _ request: GitHubWriteRequest,
        branchName: String,
        commitMessage: String
    ) async throws -> GitHubWriteResult {
        let startedAt = Date()
        do {
            guard let token = try keychain.read(account: keychainAccount), !token.isEmpty else {
                throw ConnectorError.notConfigured("GitHub")
            }

            let normalizedBranchName = try validateBranchName(branchName)
            let trimmedCommitMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommitMessage.isEmpty else {
                throw ConnectorError.invalidArguments("Commit message cannot be empty.")
            }

            Self.logger.notice("Executing approved GitHub write for \(request.repositoryFullName, privacy: .public) base=\(request.resolvedBaseRef, privacy: .public) branch=\(normalizedBranchName, privacy: .public) changeCount=\(request.changes.count, privacy: .public)")

            let client = GitHubAPIClient(token: token, session: session)
            try await ensureBranchDoesNotExist(
                owner: request.owner,
                repo: request.repo,
                branchName: normalizedBranchName,
                client: client
            )
            let afterBranchCheck = Date()

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
                    Self.logger.debug("Created blob for \(change.operation.rawValue, privacy: .public):\(change.path, privacy: .public) sha=\(self.shortSHA(blob.sha), privacy: .public)")
                    treeEntries.append(GitHubCreateTreeRequest.Entry(path: change.path, sha: blob.sha))

                case .delete:
                    Self.logger.debug("Prepared delete entry for \(change.path, privacy: .public)")
                    treeEntries.append(
                        GitHubCreateTreeRequest.Entry(path: change.path, sha: nil, isDelete: true)
                    )
                }
            }
            let afterBlobPhase = Date()

            let createdTree = try await client.createTree(
                owner: request.owner,
                repo: request.repo,
                requestBody: GitHubCreateTreeRequest(base_tree: request.baseTreeSHA, tree: treeEntries)
            )
            let afterTreeCreate = Date()
            let createdCommit = try await client.createCommit(
                owner: request.owner,
                repo: request.repo,
                message: trimmedCommitMessage,
                treeSHA: createdTree.sha,
                parentCommitSHA: request.baseCommitSHA
            )
            let afterCommitCreate = Date()
            _ = try await client.createRef(
                owner: request.owner,
                repo: request.repo,
                branchName: normalizedBranchName,
                commitSHA: createdCommit.sha
            )
            let afterRefCreate = Date()

            let createdCount = request.changes.filter { $0.operation == .create }.count
            let updatedCount = request.changes.filter { $0.operation == .update }.count
            let deletedCount = request.changes.filter { $0.operation == .delete }.count

            Self.logger.notice("GitHub write succeeded for \(request.repositoryFullName, privacy: .public) branch=\(normalizedBranchName, privacy: .public) commit=\(self.shortSHA(createdCommit.sha), privacy: .public) created=\(createdCount, privacy: .public) updated=\(updatedCount, privacy: .public) deleted=\(deletedCount, privacy: .public) branchCheckMs=\(self.elapsedMilliseconds(since: startedAt, until: afterBranchCheck), privacy: .public) blobMs=\(self.elapsedMilliseconds(since: afterBranchCheck, until: afterBlobPhase), privacy: .public) treeMs=\(self.elapsedMilliseconds(since: afterBlobPhase, until: afterTreeCreate), privacy: .public) commitMs=\(self.elapsedMilliseconds(since: afterTreeCreate, until: afterCommitCreate), privacy: .public) refMs=\(self.elapsedMilliseconds(since: afterCommitCreate, until: afterRefCreate), privacy: .public) totalMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")

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
        } catch {
            Self.logger.error("GitHub write execution failed for \(request.repositoryFullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
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

    private func executeSearchPaths(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable {
            var query: String
            var max_results: Int?
        }

        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ConnectorError.invalidArguments("query is required.")
        }
        let maxResults = max(1, min(args.max_results ?? 10, 20))
        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )

        let queryTokens = GitHubSearchNormalizer.tokenize(query)
        let rankedEntries = snapshot.treeEntries
            .map { ($0, scorePathMatch(entry: $0, query: query, queryTokens: queryTokens)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.path < $1.0.path
                }
                return $0.1 > $1.1
            }
        let rerankedEntries = rerankedStateHolderPathEntries(
            rankedEntries,
            queryTokens: queryTokens
        )
        let displayEntries = preferredSearchEntries(
            from: rerankedEntries,
            queryTokens: queryTokens,
            maxResults: maxResults
        )
        let matches = displayEntries.map { entry, score in
            GitHubPathSearchMatch(
                path: entry.path,
                kind: entry.kind,
                score: score,
                anchor: GitHubCitationAnchor(
                    repository: repositoryFullName,
                    branch: ref,
                    path: entry.path,
                    start_line: nil,
                    end_line: nil,
                    source_sha: snapshot.headSHA
                )
            )
        }

        let result = GitHubPathSearchResult(
            repository: repositoryFullName,
            branch: ref,
            query: query,
            returned_count: matches.count,
            total_matching_count: rerankedEntries.count,
            results: matches
        )
        Self.logger.debug("Searched GitHub paths for \(repositoryFullName, privacy: .public) branch=\(ref, privacy: .public) query=\(query, privacy: .public) indexedEntries=\(snapshot.treeEntries.count, privacy: .public) returned=\(matches.count, privacy: .public) totalMatches=\(rerankedEntries.count, privacy: .public) elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: snapshot
        )
    }

    private func executeSearchCode(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable {
            var query: String
            var max_results: Int?
        }

        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ConnectorError.invalidArguments("query is required.")
        }
        let maxResults = max(1, min(args.max_results ?? 10, 20))
        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )

        var repository = snapshot
        var scoredMatches: [ScoredCodeSearchMatch] = []
        var searchedFiles = 0
        let queryTokens = GitHubSearchNormalizer.tokenize(query)
        let candidateEntries = repository.treeEntries
            .filter { $0.kind == .file && isLikelyTextFile(path: $0.path) }
            .map { ($0, scoreCodeSearchCandidate(entry: $0, queryTokens: queryTokens)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.path < $1.0.path
                }
                return $0.1 > $1.1
            }
        let rerankedCandidateEntries = rerankedStateHolderCodeCandidates(
            candidateEntries,
            queryTokens: queryTokens
        )
        let limitedCandidates = Array(rerankedCandidateEntries.prefix(Self.maxCodeSearchCandidateFiles))

        for (entry, pathRelevanceScore) in limitedCandidates {
            do {
                let readResult = try await syncCoordinator.readTextFile(
                    from: repository,
                    owner: owner,
                    repo: repo,
                    branch: ref,
                    repositoryFullName: repositoryFullName,
                    path: entry.path,
                    client: client
                )
                let indexedFile = readResult.file
                repository = readResult.repository
                searchedFiles += 1
                if let match = makeCodeSearchMatch(
                    repositoryFullName: repositoryFullName,
                    branch: ref,
                    query: query,
                    queryTokens: queryTokens,
                    indexedFile: indexedFile,
                    sourceSHA: snapshot.headSHA,
                    pathRelevanceScore: pathRelevanceScore
                ) {
                    scoredMatches.append(match)
                }
            } catch {
                continue
            }
        }

        let matches = scoredMatches
            .sorted {
                if $0.score == $1.score {
                    return $0.match.path < $1.match.path
                }
                return $0.score > $1.score
            }
        let rankedMatches = Array(matches)
        let preferredMatches = preferredCodeSearchMatches(
            from: rankedMatches,
            queryTokens: queryTokens,
            maxResults: maxResults
        )
        let result = GitHubCodeSearchResult(
            repository: repositoryFullName,
            branch: ref,
            query: query,
            returned_count: preferredMatches.count,
            searched_files: searchedFiles,
            results: preferredMatches
        )
        Self.logger.debug("Searched GitHub code for \(repositoryFullName, privacy: .public) branch=\(ref, privacy: .public) query=\(query, privacy: .public) candidateFiles=\(rerankedCandidateEntries.count, privacy: .public) scannedCandidates=\(limitedCandidates.count, privacy: .public) searchedFiles=\(searchedFiles, privacy: .public) returned=\(preferredMatches.count, privacy: .public) validationCalls=1 elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: repository
        )
    }

    private func executeGetRepoContents(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var path: String?; var ref: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let items = try await client.getRepoContents(owner: args.owner, repo: args.repo, path: args.path ?? "", ref: args.ref)
        Self.logger.debug("Read GitHub repo contents for \(args.owner, privacy: .public)/\(args.repo, privacy: .public) ref=\(args.ref ?? "<default>", privacy: .public) path=\(self.displayPath(args.path), privacy: .public) itemCount=\(items.count, privacy: .public)")
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
        Self.logger.debug("Read GitHub repo contents for \(owner, privacy: .public)/\(repo, privacy: .public) ref=\(ref, privacy: .public) path=\(self.displayPath(args.path), privacy: .public) itemCount=\(items.count, privacy: .public)")
        let result: [[String: String]] = items.map(\.summary)
        return try encodeResult(["items": result])
    }

    private func executeGetRepoTree(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable {
            var path_prefix: String?
            var entry_type: String?
            var max_entries: Int?
        }

        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        let pathPrefix = try normalizeTreePathPrefix(args.path_prefix)
        let entryFilter = try parseTreeEntryFilter(args.entry_type)
        let maxEntries = try validateMaxTreeEntries(args.max_entries)

        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )
        let matchingEntries = snapshot.treeEntries
            .map { GitHubRepoTreeEntry(path: $0.path, kind: $0.kind, size: $0.size) }
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
            truncated: matchingEntries.count > limitedEntries.count,
            entries: limitedEntries,
            advisory: matchingEntries.isEmpty && pathPrefix != nil
                ? "No entries matched '\(pathPrefix ?? "")' in this repository. Reuse the earlier root tree result or use github_search_paths for conceptual file names instead of scanning more missing subtrees."
                : nil
        )
        Self.logger.debug("Read GitHub repo tree for \(repositoryFullName, privacy: .public) branch=\(ref, privacy: .public) prefix=\(pathPrefix ?? "/", privacy: .public) entryType=\(entryFilter.rawValue, privacy: .public) indexedEntries=\(snapshot.treeEntries.count, privacy: .public) returned=\(result.returned_count, privacy: .public) total=\(result.total_matching_count, privacy: .public) truncated=\(result.truncated, privacy: .public) elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: snapshot
        )
    }

    private func executeGetFileContent(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var path: String; var ref: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let file = try await client.getFileContent(owner: args.owner, repo: args.repo, path: args.path, ref: args.ref)
        var result: [String: String] = [
            "path": file.path,
            "size": "\(file.size)"
        ]
        if let decoded = file.decodedContent {
            if decoded.count > Self.maxReturnedFileContentCharacters {
                result["content"] = String(decoded.prefix(Self.maxReturnedFileContentCharacters)) + "\n\n[Content truncated at \(Self.maxReturnedFileContentCharacters) characters]"
                result["truncated"] = "true"
            } else {
                result["content"] = decoded
            }
        }
        let wasTruncated = result["truncated"] == "true"
        Self.logger.debug("Read GitHub file for \(args.owner, privacy: .public)/\(args.repo, privacy: .public) ref=\(args.ref ?? "<default>", privacy: .public) path=\(args.path, privacy: .public) size=\(file.size, privacy: .public) truncated=\(wasTruncated, privacy: .public)")
        return try encodeResult(result)
    }

    private func executeGetFileContent(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable { var path: String }
        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )
        let readResult = try await syncCoordinator.readTextFile(
            from: snapshot,
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            path: args.path,
            client: client
        )
        let file = readResult.file
        var result: [String: String] = [
            "path": file.path,
            "size": "\(file.size)",
            "repository": repositoryFullName,
            "branch": ref
        ]
        if let sha = file.sha {
            result["source_sha"] = sha
        }
        if file.content.count > Self.maxReturnedFileContentCharacters {
            result["content"] = String(file.content.prefix(Self.maxReturnedFileContentCharacters)) + "\n\n[Content truncated at \(Self.maxReturnedFileContentCharacters) characters]"
            result["truncated"] = "true"
        } else {
            result["content"] = file.content
        }
        let wasTruncated = result["truncated"] == "true"
        Self.logger.debug("Read GitHub file for \(owner, privacy: .public)/\(repo, privacy: .public) ref=\(ref, privacy: .public) path=\(args.path, privacy: .public) size=\(file.size, privacy: .public) truncated=\(wasTruncated, privacy: .public) elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: readResult.repository
        )
    }

    private func executeGetFileLines(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable {
            var path: String
            var start_line: Int
            var end_line: Int
        }

        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        guard args.start_line > 0 else {
            throw ConnectorError.invalidArguments("start_line must be greater than 0.")
        }
        guard args.end_line >= args.start_line else {
            throw ConnectorError.invalidArguments("end_line must be greater than or equal to start_line.")
        }

        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )
        let readResult = try await syncCoordinator.readTextFile(
            from: snapshot,
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            path: args.path,
            client: client
        )
        let file = readResult.file

        let allLines = file.content.isEmpty ? [] : splitLines(file.content)
        let startIndex = min(max(args.start_line - 1, 0), allLines.count)
        let endIndexExclusive = min(args.end_line, allLines.count)
        let selectedLines = startIndex < endIndexExclusive ? Array(allLines[startIndex..<endIndexExclusive]) : []
        var content = selectedLines.joined(separator: "\n")
        var wasTruncated = false
        if content.count > Self.maxReturnedFileContentCharacters {
            content = String(content.prefix(Self.maxReturnedFileContentCharacters))
            wasTruncated = true
        }

        let result = GitHubFileLinesResult(
            path: file.path,
            size: file.size,
            start_line: selectedLines.isEmpty ? 0 : args.start_line,
            end_line: selectedLines.isEmpty ? 0 : min(args.end_line, allLines.count),
            line_count: selectedLines.count,
            content: content,
            truncated: wasTruncated,
            anchor: GitHubCitationAnchor(
                repository: repositoryFullName,
                branch: ref,
                path: file.path,
                start_line: selectedLines.isEmpty ? nil : args.start_line,
                end_line: selectedLines.isEmpty ? nil : min(args.end_line, allLines.count),
                source_sha: file.sha
            )
        )
        Self.logger.debug("Read GitHub file lines for \(owner, privacy: .public)/\(repo, privacy: .public) ref=\(ref, privacy: .public) path=\(args.path, privacy: .public) lines=\(result.start_line, privacy: .public)-\(result.end_line, privacy: .public) truncated=\(result.truncated, privacy: .public) elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: readResult.repository
        )
    }

    private func executeGetFileTail(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        ref: String,
        repositoryFullName: String,
        argsData: Data,
        validatedRepository: GitHubIndexedRepository?
    ) async throws -> ExecutionResult {
        struct Args: Decodable {
            var path: String
            var max_lines: Int?
        }

        let startedAt = Date()
        let args = try decodeArgs(Args.self, from: argsData)
        let maxLines = try validateMaxTailLines(args.max_lines)
        let snapshot = try await syncCoordinator.ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            client: client,
            validatedRepository: validatedRepository
        )
        let readResult = try await syncCoordinator.readTextFile(
            from: snapshot,
            owner: owner,
            repo: repo,
            branch: ref,
            repositoryFullName: repositoryFullName,
            path: args.path,
            client: client
        )
        let file = readResult.file

        let allLines = file.content.isEmpty ? [] : splitLines(file.content)
        let endLine = allLines.count
        let startIndex = max(0, endLine - maxLines)
        let startLine = endLine == 0 ? 0 : startIndex + 1
        let tailLines = Array(allLines.suffix(maxLines))
        var tailContent = tailLines.joined(separator: "\n")
        let lineCount = tailLines.count
        var wasTruncated = startIndex > 0

        if tailContent.count > Self.maxReturnedFileContentCharacters {
            tailContent = String(tailContent.suffix(Self.maxReturnedFileContentCharacters))
            wasTruncated = true
        }

        let result = GitHubFileTailResult(
            path: file.path,
            size: file.size,
            start_line: startLine,
            end_line: endLine,
            line_count: lineCount,
            content: tailContent,
            truncated: wasTruncated,
            anchor: GitHubCitationAnchor(
                repository: repositoryFullName,
                branch: ref,
                path: file.path,
                start_line: startLine == 0 ? nil : startLine,
                end_line: endLine == 0 ? nil : endLine,
                source_sha: file.sha
            )
        )
        Self.logger.debug("Read GitHub file tail for \(owner, privacy: .public)/\(repo, privacy: .public) ref=\(ref, privacy: .public) path=\(args.path, privacy: .public) size=\(file.size, privacy: .public) lines=\(result.start_line, privacy: .public)-\(result.end_line, privacy: .public) truncated=\(result.truncated, privacy: .public) elapsedMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return ExecutionResult(
            output: try encodeResult(result),
            validatedRepository: readResult.repository
        )
    }

    private func executeListBranches(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let branches = try await client.listBranches(owner: owner, repo: repo, perPage: args.per_page ?? 100)
        let result = GitHubBranchListResult(
            branches: branches.map { branch in
                var summary: [String: String] = ["name": branch.name]
                if let sha = branch.commit?.sha {
                    summary["sha"] = sha
                }
                return summary
            }
        )
        return try encodeResult(result)
    }

    private func executeListCommits(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var ref: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let commits = try await client.listCommits(owner: owner, repo: repo, sha: args.ref, perPage: args.per_page ?? 10)
        return try encodeResult(GitHubCommitListResult(commits: commits.map(\.summary)))
    }

    private func executeCompareRefs(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable {
            var base: String
            var head: String
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let comparison = try await client.compareRefs(owner: owner, repo: repo, base: args.base, head: args.head)
        let result = GitHubCompareResult(
            base: args.base,
            head: args.head,
            status: comparison.status,
            ahead_by: comparison.ahead_by,
            behind_by: comparison.behind_by,
            total_commits: comparison.total_commits,
            html_url: comparison.html_url,
            commits: comparison.commits.map {
                var summary: [String: String] = [
                    "sha": $0.sha,
                    "message": $0.commit.message
                ]
                if let html_url = $0.html_url {
                    summary["html_url"] = html_url
                }
                if let date = $0.commit.author?.date {
                    summary["date"] = date
                }
                return summary
            },
            files: (comparison.files ?? []).map {
                var summary: [String: String] = [
                    "filename": $0.filename,
                    "status": $0.status
                ]
                if let additions = $0.additions {
                    summary["additions"] = "\(additions)"
                }
                if let deletions = $0.deletions {
                    summary["deletions"] = "\(deletions)"
                }
                if let changes = $0.changes {
                    summary["changes"] = "\(changes)"
                }
                if let patch = $0.patch {
                    summary["patch"] = patch
                }
                return summary
            }
        )
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

    private func executeSearchIssues(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct SearchIssuesResult: Encodable {
            var total_count: Int
            var issues: [[String: String]]
        }

        struct Args: Decodable {
            var query: String
            var per_page: Int?
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let response = try await client.searchIssues(
            owner: owner,
            repo: repo,
            query: args.query,
            includePullRequests: false,
            perPage: args.per_page ?? 10
        )
        return try encodeResult(
            SearchIssuesResult(
                total_count: response.total_count,
                issues: response.items.filter { !$0.isPullRequest }.map(\.summary)
            )
        )
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

    private func executeSearchPullRequests(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct SearchPullRequestsResult: Encodable {
            var total_count: Int
            var pull_requests: [[String: String]]
        }

        struct Args: Decodable {
            var query: String
            var per_page: Int?
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let response = try await client.searchIssues(
            owner: owner,
            repo: repo,
            query: args.query,
            includePullRequests: true,
            perPage: args.per_page ?? 10
        )
        return try encodeResult(
            SearchPullRequestsResult(
                total_count: response.total_count,
                pull_requests: response.items.filter(\.isPullRequest).map(\.summary)
            )
        )
    }

    private func executeGetPullRequestFiles(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable {
            var number: Int
            var per_page: Int?
        }

        let args = try decodeArgs(Args.self, from: argsData)
        let files = try await client.listPullRequestFiles(owner: owner, repo: repo, number: args.number, perPage: args.per_page ?? 100)
        return try encodeResult(["files": files.map(\.summary)])
    }

    private func executeGetPullRequestDiff(
        client: GitHubAPIClient,
        owner: String,
        repo: String,
        argsData: Data
    ) async throws -> String {
        struct Args: Decodable { var number: Int }
        let args = try decodeArgs(Args.self, from: argsData)
        let diff = try await client.getPullRequestDiff(owner: owner, repo: repo, number: args.number)
        let wasTruncated = diff.count > Self.maxDiffPreviewCharacters
        let result = GitHubPullRequestDiffResult(
            number: args.number,
            diff: wasTruncated ? String(diff.prefix(Self.maxDiffPreviewCharacters)) + "\n\n[Diff truncated]" : diff,
            truncated: wasTruncated
        )
        return try encodeResult(result)
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
        let startedAt = Date()
        let trimmedCommitMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommitMessage.isEmpty else {
            throw ConnectorError.invalidArguments("commit_message is required.")
        }

        let normalizedChanges = try normalizeChanges(changes)
        Self.logger.notice("GitHub write preflight started for \(owner, privacy: .public)/\(repo, privacy: .public) requestedBase=\(requestedBaseRef ?? "<auto>", privacy: .public) requestedBranch=\(requestedBranchName ?? "<auto>", privacy: .public) normalizedChangeCount=\(normalizedChanges.count, privacy: .public)")
        let client = try makeClient()
        let repository = try await client.getRepository(owner: owner, repo: repo)
        let afterRepositoryLookup = Date()
        let baseResolution = try await resolveBaseRef(
            requestedBaseRef: requestedBaseRef,
            owner: owner,
            repo: repo,
            repository: repository,
            client: client
        )
        let afterBaseResolution = Date()

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
        let afterBranchCheck = Date()

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
        let afterTreeLoad = Date()

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
        let afterDiffPreviewBuild = Date()

        let request = GitHubWriteRequest(
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
        Self.logger.notice("GitHub write preflight completed for \(request.repositoryFullName, privacy: .public) resolvedBase=\(request.resolvedBaseRef, privacy: .public) proposedBranch=\(request.proposedBranchName, privacy: .public) baseCommit=\(self.shortSHA(request.baseCommitSHA), privacy: .public) diffPreviewCount=\(request.diffPreviews.count, privacy: .public) repoLookupMs=\(self.elapsedMilliseconds(since: startedAt, until: afterRepositoryLookup), privacy: .public) baseResolveMs=\(self.elapsedMilliseconds(since: afterRepositoryLookup, until: afterBaseResolution), privacy: .public) branchCheckMs=\(self.elapsedMilliseconds(since: afterBaseResolution, until: afterBranchCheck), privacy: .public) treeLoadMs=\(self.elapsedMilliseconds(since: afterBranchCheck, until: afterTreeLoad), privacy: .public) diffPreviewMs=\(self.elapsedMilliseconds(since: afterTreeLoad, until: afterDiffPreviewBuild), privacy: .public) totalMs=\(self.elapsedMilliseconds(since: startedAt), privacy: .public)")
        return request
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
        return min(resolved, 1_000)
    }

    private func validateMaxTailLines(_ rawValue: Int?) throws -> Int {
        let resolved = rawValue ?? 80
        guard resolved > 0 else {
            throw ConnectorError.invalidArguments("max_lines must be greater than 0.")
        }
        return min(resolved, 300)
    }

    private func scorePathMatch(entry: GitHubIndexedTreeEntry, query: String, queryTokens: [String]? = nil) -> Int {
        let queryTokens = Array(Set(queryTokens ?? GitHubSearchNormalizer.tokenize(query))).sorted()
        guard !queryTokens.isEmpty else {
            return 0
        }
        let normalizedQuery = GitHubSearchNormalizer.normalizedSearchString(query)
        let normalizedPath = normalizedSearchString(entry.path)
        let fileName = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
        let normalizedFileName = normalizedSearchString(fileName)
        let pathTokens = Set(searchTokens(for: entry.path))
        let matchedTokens = queryTokens.filter { pathTokens.contains($0) }
        let matchedDomainTokens = queryDomainTokens(in: queryTokens).filter { pathTokens.contains($0) }
        let matchedArchitectureTokens = queryArchitectureTokens(in: queryTokens).filter { pathTokens.contains($0) }
        let relatedTokens = relatedSearchTokens(for: queryTokens)
        let matchedRelatedTokens = relatedTokens.filter { token in
            pathTokens.contains(token) && !matchedTokens.contains(token)
        }
        let exactOrNearExactMatch =
            normalizedPath == normalizedQuery ||
            normalizedFileName == normalizedQuery ||
            normalizedPath.contains(normalizedQuery) ||
            normalizedFileName.contains(normalizedQuery)

        var score = 0
        if normalizedPath == normalizedQuery {
            score += 380
        }
        if normalizedFileName == normalizedQuery {
            score += 340
        }
        if normalizedPath.contains(normalizedQuery) {
            score += 220
        }
        if normalizedFileName.contains(normalizedQuery) {
            score += 240
        }

        score += matchedTokens.count * 110
        if matchedTokens.count == queryTokens.count {
            score += 170
        } else if queryTokens.count > 1, matchedTokens.count >= queryTokens.count - 1 {
            score += 70
        }
        score += matchedRelatedTokens.count * 35
        score += queryAwarePathBonus(pathTokens: pathTokens, queryTokens: queryTokens)
        score += searchFileCategoryBonus(path: entry.path, queryTokens: queryTokens, forCodeSearch: false)
        score += directoryCohesionBonus(path: entry.path, queryTokens: queryTokens)

        switch entry.kind {
        case .file:
            if isSourceFile(path: entry.path) {
                score += 20
            }
        case .directory:
            score -= 35
        default:
            break
        }

        let hasDirectSignal =
            !matchedTokens.isEmpty ||
            normalizedPath.contains(normalizedQuery) ||
            normalizedFileName.contains(normalizedQuery)
        let hasRelatedSignal = !matchedRelatedTokens.isEmpty
        let hasArchitectureSignal =
            !matchedArchitectureTokens.isEmpty ||
            matchedRelatedTokens.contains { architectureSignalTokens.contains($0) }
        let requiresDomainMatch = queryRequiresDomainArchitectureGating(queryTokens)

        if requiresDomainMatch,
           matchedDomainTokens.isEmpty,
           !exactOrNearExactMatch {
            return 0
        }
        if requiresDomainMatch,
           !hasArchitectureSignal,
           (!isSourceFile(path: entry.path) || !hasDirectSignal) {
            return 0
        }

        guard hasDirectSignal || hasRelatedSignal else {
            return 0
        }

        let minimumScore = hasDirectSignal ? 120 : 160
        return score >= minimumScore ? score : 0
    }

    private func searchTokens(for value: String) -> [String] {
        GitHubSearchNormalizer.tokenize(value)
    }

    private func normalizedSearchString(_ value: String) -> String {
        GitHubSearchNormalizer.normalizedSearchString(value)
    }

    private func relatedSearchTokens(for queryTokens: [String]) -> Set<String> {
        queryTokens.reduce(into: Set<String>()) { partialResult, token in
            switch token {
            case "state":
                partialResult.formUnion(["model", "models", "viewmodel", "viewmodels", "context", "contexts", "settings", "selection", "session", "store", "stores"])
            case "connector", "connectors":
                partialResult.formUnion(["github", "connectors", "connector", "integration"])
            case "github":
                partialResult.formUnion(["connector", "connectors", "integration"])
            default:
                break
            }
        }
    }

    private func queryAwarePathBonus(pathTokens: Set<String>, queryTokens: [String]) -> Int {
        let stateLikeTokens: Set<String> = ["model", "models", "viewmodel", "viewmodels", "context", "contexts", "settings", "selection", "session", "store", "stores"]
        let domainTokens = queryDomainTokens(in: queryTokens)
        var score = 0

        if domainTokens.contains("connector"), !pathTokens.isDisjoint(with: ["connector", "connectors"]) {
            score += 140
        }
        if (!domainTokens.isEmpty),
           pathTokens.contains("github") {
            score += 110
        }
        if queryTokens.contains("state"), !pathTokens.isDisjoint(with: stateLikeTokens) {
            score += 90
        }

        return score
    }

    private func scoreCodeSearchCandidate(entry: GitHubIndexedTreeEntry, queryTokens: [String]) -> Int {
        guard entry.kind == .file else {
            return 0
        }

        let pathTokens = Set(searchTokens(for: entry.path))
        let matchedTokenCount = queryTokens.filter { pathTokens.contains($0) }.count
        let matchedDomainTokens = queryDomainTokens(in: queryTokens).filter { pathTokens.contains($0) }
        let matchedArchitectureTokens = queryArchitectureTokens(in: queryTokens).filter { pathTokens.contains($0) }
        let hasDomainArchitectureGating = queryRequiresDomainArchitectureGating(queryTokens)
        let relatedArchitectureSignal = !pathTokens.isDisjoint(with: architectureSignalTokens)
        var score = searchFileCategoryBonus(path: entry.path, queryTokens: queryTokens, forCodeSearch: true)
        score += matchedTokenCount * 90
        score += queryAwarePathBonus(pathTokens: pathTokens, queryTokens: queryTokens)
        score += directoryCohesionBonus(path: entry.path, queryTokens: queryTokens)

        if isSourceFile(path: entry.path) {
            score += 40
        }

        if hasDomainArchitectureGating,
           matchedDomainTokens.isEmpty,
           !normalizedSearchString(entry.path).contains(queryTokens.joined(separator: " ")) {
            return 0
        }
        if hasDomainArchitectureGating,
           matchedArchitectureTokens.isEmpty,
           !relatedArchitectureSignal,
           (!isSourceFile(path: entry.path) || matchedTokenCount == 0) {
            return 0
        }

        return max(score, 0)
    }

    private func searchFileCategoryBonus(
        path: String,
        queryTokens: [String],
        forCodeSearch: Bool
    ) -> Int {
        let lowercasedPath = path.lowercased()
        let docQueryTokens: Set<String> = ["doc", "docs", "documentation", "guide", "readme", "markdown", "md"]
        let projectQueryTokens: Set<String> = ["xcode", "scheme", "project", "workspace", "pbxproj", "plist", "xcuserdata"]
        let assetQueryTokens: Set<String> = ["asset", "assets", "icon", "color", "colors", "xcassets", "image"]
        let queryTokenSet = Set(queryTokens)

        if lowercasedPath.hasSuffix(".swift") ||
            lowercasedPath.hasSuffix(".m") ||
            lowercasedPath.hasSuffix(".mm") ||
            lowercasedPath.hasSuffix(".h") ||
            lowercasedPath.hasSuffix(".hpp") ||
            lowercasedPath.hasSuffix(".c") ||
            lowercasedPath.hasSuffix(".cc") ||
            lowercasedPath.hasSuffix(".cpp") ||
            lowercasedPath.hasSuffix(".kt") ||
            lowercasedPath.hasSuffix(".java") ||
            lowercasedPath.hasSuffix(".go") ||
            lowercasedPath.hasSuffix(".rs") ||
            lowercasedPath.hasSuffix(".js") ||
            lowercasedPath.hasSuffix(".ts") ||
            lowercasedPath.hasSuffix(".tsx") ||
            lowercasedPath.hasSuffix(".jsx") {
            return forCodeSearch ? 180 : 80
        }

        if lowercasedPath.contains("/tests/") || lowercasedPath.hasSuffix("tests.swift") {
            return queryTokenSet.contains("test") || queryTokenSet.contains("tests")
                ? (forCodeSearch ? 80 : 50)
                : (forCodeSearch ? -40 : -25)
        }

        if lowercasedPath.hasSuffix(".md") || lowercasedPath.hasSuffix(".markdown") || lowercasedPath.hasSuffix(".txt") {
            if !queryTokenSet.isDisjoint(with: docQueryTokens) {
                return 90
            }
            if forCodeSearch {
                return -80
            }
            return queryTokenSet.contains("state") ? -320 : -220
        }

        if lowercasedPath.contains(".xcassets/") {
            return queryTokenSet.isDisjoint(with: assetQueryTokens)
                ? (forCodeSearch ? -180 : -80)
                : 50
        }

        if lowercasedPath.contains(".xcodeproj/") ||
            lowercasedPath.contains(".xcworkspace/") ||
            lowercasedPath.contains("/xcuserdata/") ||
            lowercasedPath.hasSuffix(".pbxproj") {
            return queryTokenSet.isDisjoint(with: projectQueryTokens)
                ? (forCodeSearch ? -220 : -120)
                : 80
        }

        if lowercasedPath.hasSuffix(".plist") || lowercasedPath.hasSuffix(".json") || lowercasedPath.hasSuffix(".yml") || lowercasedPath.hasSuffix(".yaml") {
            return queryTokenSet.isDisjoint(with: projectQueryTokens.union(assetQueryTokens))
                ? (forCodeSearch ? -110 : -30)
                : 35
        }

        if lowercasedPath.hasPrefix(".") {
            return forCodeSearch ? -140 : -60
        }

        return forCodeSearch ? 40 : 10
    }

    private func queryRequiresDomainArchitectureGating(_ queryTokens: [String]) -> Bool {
        let domainTokens = queryDomainTokens(in: queryTokens)
        let architectureTokens = queryArchitectureTokens(in: queryTokens)
        return !domainTokens.isEmpty && !architectureTokens.isEmpty
    }

    private func queryDomainTokens(in queryTokens: [String]) -> Set<String> {
        var domainTokens: Set<String> = []
        if queryTokens.contains("github") {
            domainTokens.insert("github")
        }
        if queryTokens.contains("connector") || queryTokens.contains("connectors") {
            domainTokens.insert("connector")
            domainTokens.insert("connectors")
        }
        return domainTokens
    }

    private func queryArchitectureTokens(in queryTokens: [String]) -> Set<String> {
        let architectureTokenUniverse: Set<String> = [
            "state", "context", "settings", "session", "selection", "store", "stores",
            "model", "models", "viewmodel", "viewmodels"
        ]
        return Set(queryTokens.filter { architectureTokenUniverse.contains($0) })
    }

    private func directoryCohesionBonus(path: String, queryTokens: [String]) -> Int {
        let components = path
            .split(separator: "/")
            .dropLast()
            .map(String.init)
        guard !components.isEmpty else {
            return 0
        }

        let directoryTokens = Set(components.flatMap(searchTokens(for:)))
        let matchedCount = queryTokens.filter { directoryTokens.contains($0) }.count
        guard matchedCount > 0 else {
            return 0
        }

        return matchedCount * 35 + (matchedCount >= 2 ? 40 : 0)
    }

    private var architectureSignalTokens: Set<String> {
        [
            "state", "context", "settings", "session", "selection", "store", "stores",
            "model", "models", "viewmodel", "viewmodels"
        ]
    }

    private func preferredSearchEntries(
        from rankedEntries: [(GitHubIndexedTreeEntry, Int)],
        queryTokens: [String],
        maxResults: Int
    ) -> [(GitHubIndexedTreeEntry, Int)] {
        let wantsTests = Set(queryTokens).intersection(["test", "tests"]).isEmpty == false
        guard !wantsTests else {
            return Array(rankedEntries.prefix(maxResults))
        }

        let productionEntries = rankedEntries.filter { !isTestPath($0.0.path) }
        if isStateHolderQuery(queryTokens) {
            let anchorTokens = stateHolderAnchorTokens(from: productionEntries.map(\.0), queryTokens: queryTokens)
            let clusteredEntries = productionEntries.filter {
                shouldIncludeStateHolderResult(
                    path: $0.0.path,
                    anchorTokens: anchorTokens,
                    queryTokens: queryTokens
                )
            }
            if !clusteredEntries.isEmpty {
                return Array(clusteredEntries.prefix(maxResults))
            }
        }

        if productionEntries.count >= 5 {
            return Array(productionEntries.prefix(maxResults))
        }

        return Array(rankedEntries.prefix(maxResults))
    }

    private func preferredCodeSearchMatches(
        from scoredMatches: [ScoredCodeSearchMatch],
        queryTokens: [String],
        maxResults: Int
    ) -> [GitHubCodeSearchMatch] {
        let wantsTests = Set(queryTokens).intersection(["test", "tests"]).isEmpty == false
        guard !wantsTests else {
            return Array(scoredMatches.prefix(maxResults)).map(\.match)
        }

        let productionMatches = scoredMatches.filter { !isTestPath($0.match.path) }
        if isStateHolderQuery(queryTokens) {
            let anchorTokens = stateHolderAnchorTokens(from: productionMatches.map(\.match.path), queryTokens: queryTokens)
            let clusteredMatches = productionMatches.filter {
                shouldIncludeStateHolderResult(
                    path: $0.match.path,
                    anchorTokens: anchorTokens,
                    queryTokens: queryTokens
                )
            }
            if !clusteredMatches.isEmpty {
                return Array(clusteredMatches.prefix(maxResults)).map(\.match)
            }
        }

        let selected = productionMatches.count >= 5
            ? Array(productionMatches.prefix(maxResults))
            : Array(scoredMatches.prefix(maxResults))
        return selected.map(\.match)
    }

    private func rerankedStateHolderPathEntries(
        _ rankedEntries: [(GitHubIndexedTreeEntry, Int)],
        queryTokens: [String]
    ) -> [(GitHubIndexedTreeEntry, Int)] {
        guard isStateHolderQuery(queryTokens) else {
            return rankedEntries
        }

        let anchorTokens = stateHolderAnchorTokens(from: rankedEntries.map(\.0), queryTokens: queryTokens)
        return rankedEntries
            .map { entry, score in
                (entry, score + stateHolderScoreAdjustment(path: entry.path, anchorTokens: anchorTokens, queryTokens: queryTokens))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.path < $1.0.path
                }
                return $0.1 > $1.1
            }
    }

    private func rerankedStateHolderCodeCandidates(
        _ candidateEntries: [(GitHubIndexedTreeEntry, Int)],
        queryTokens: [String]
    ) -> [(GitHubIndexedTreeEntry, Int)] {
        guard isStateHolderQuery(queryTokens) else {
            return candidateEntries
        }

        let anchorTokens = stateHolderAnchorTokens(from: candidateEntries.map(\.0), queryTokens: queryTokens)
        return candidateEntries
            .map { entry, score in
                (entry, score + stateHolderScoreAdjustment(path: entry.path, anchorTokens: anchorTokens, queryTokens: queryTokens))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.path < $1.0.path
                }
                return $0.1 > $1.1
            }
    }

    private func isStateHolderQuery(_ queryTokens: [String]) -> Bool {
        let stateHolderTokens: Set<String> = [
            "state", "context", "settings", "selection", "session",
            "store", "stores", "cache", "index", "model", "models", "viewmodel", "viewmodels"
        ]
        return !Set(queryTokens).isDisjoint(with: stateHolderTokens)
    }

    private func stateHolderAnchorTokens(
        from entries: [GitHubIndexedTreeEntry],
        queryTokens: [String]
    ) -> Set<String> {
        for entry in entries where isSourceFile(path: entry.path) {
            let tokens = subsystemClusterTokens(for: entry.path)
            if !tokens.isEmpty {
                return tokens
            }
        }
        return queryDomainTokens(in: queryTokens)
    }

    private func stateHolderAnchorTokens(
        from paths: [String],
        queryTokens: [String]
    ) -> Set<String> {
        for path in paths where isSourceFile(path: path) {
            let tokens = subsystemClusterTokens(for: path)
            if !tokens.isEmpty {
                return tokens
            }
        }
        return queryDomainTokens(in: queryTokens)
    }

    private func shouldIncludeStateHolderResult(
        path: String,
        anchorTokens: Set<String>,
        queryTokens: [String]
    ) -> Bool {
        if isProtocolLikePath(path) || isTestPath(path) || isDocumentationPath(path) || isAssetOrProjectPath(path) {
            return false
        }

        let pathTokens = Set(searchTokens(for: path))
        let sharesAnchorTokens = anchorTokens.isEmpty == false && !pathTokens.isDisjoint(with: anchorTokens)
        let hasStateSignals = hasStateBearingSignals(path)

        if isGenericViewPath(path), !hasStateSignals {
            return false
        }
        if isConnectorSiblingNoise(path, anchorTokens: anchorTokens), !hasStateSignals {
            return false
        }
        if sharesAnchorTokens || hasStateSignals {
            return true
        }

        return false
    }

    private func stateHolderScoreAdjustment(
        path: String,
        anchorTokens: Set<String>,
        queryTokens: [String]
    ) -> Int {
        let pathTokens = Set(searchTokens(for: path))
        let sharesAnchorTokens = anchorTokens.isEmpty == false && !pathTokens.isDisjoint(with: anchorTokens)
        let hasStateSignals = hasStateBearingSignals(path)
        var adjustment = 0

        if sharesAnchorTokens {
            adjustment += 180
        }
        if hasStateSignals {
            adjustment += 170
        }
        if isProtocolLikePath(path) {
            adjustment -= 260
        }
        if isTestPath(path) {
            adjustment -= 260
        }
        if isDocumentationPath(path) {
            adjustment -= 280
        }
        if isAssetOrProjectPath(path) {
            adjustment -= 280
        }
        if isConnectorSiblingNoise(path, anchorTokens: anchorTokens) {
            adjustment -= 220
        }
        if isGenericViewPath(path), !hasStateSignals {
            adjustment -= 150
        }
        if !anchorTokens.isEmpty,
           !sharesAnchorTokens,
           isSourceFile(path: path),
           queryDomainTokens(in: queryTokens).isEmpty == false {
            adjustment -= 80
        }

        return adjustment
    }

    private func hasStateBearingSignals(_ path: String) -> Bool {
        let pathTokens = Set(searchTokens(for: path))
        let stateBearingTokens: Set<String> = [
            "state", "context", "settings", "selection", "session", "store", "stores",
            "cache", "index", "model", "models", "viewmodel", "viewmodels"
        ]
        return !pathTokens.isDisjoint(with: stateBearingTokens)
    }

    private func subsystemClusterTokens(for path: String) -> Set<String> {
        let stopwords: Set<String> = [
            "porch", "services", "service", "connectors", "connector", "view", "views",
            "viewmodel", "viewmodels", "model", "models", "utilities", "utility", "shared",
            "chat", "settings", "tests", "test", "docs", "doc", "sources", "source",
            "swift", "state", "context", "selection", "session", "store", "stores",
            "cache", "index", "api", "client", "sheet", "protocol"
        ]
        return Set(searchTokens(for: path)).subtracting(stopwords)
    }

    private func isProtocolLikePath(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.hasSuffix("protocol.swift") || lowercasedPath.contains("protocol")
    }

    private func isDocumentationPath(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.contains("/docs/") ||
            lowercasedPath.hasSuffix(".md") ||
            lowercasedPath.hasSuffix(".markdown") ||
            lowercasedPath.hasSuffix(".txt")
    }

    private func isAssetOrProjectPath(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.contains(".xcassets/") ||
            lowercasedPath.contains(".xcodeproj/") ||
            lowercasedPath.contains(".xcworkspace/") ||
            lowercasedPath.contains("/xcuserdata/") ||
            lowercasedPath.hasSuffix(".pbxproj")
    }

    private func isGenericViewPath(_ path: String) -> Bool {
        path.lowercased().contains("/views/")
    }

    private func isConnectorSiblingNoise(_ path: String, anchorTokens: Set<String>) -> Bool {
        let lowercasedPath = path.lowercased()
        guard lowercasedPath.contains("/connectors/"),
              !anchorTokens.isEmpty else {
            return false
        }
        let pathTokens = Set(searchTokens(for: path))
        return pathTokens.isDisjoint(with: anchorTokens)
    }

    private func isTestPath(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.contains("/tests/") || lowercasedPath.hasSuffix("tests.swift")
    }

    private func isSourceFile(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let sourceExtensions: Set<String> = [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "kt", "java", "go", "rs", "js", "ts", "tsx", "jsx"
        ]
        return sourceExtensions.contains(ext)
    }

    private func isLikelyTextFile(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext.isEmpty { return true }
        let supportedExtensions: Set<String> = [
            "swift", "md", "markdown", "txt", "json", "yml", "yaml", "xml", "pbxproj",
            "plist", "strings", "html", "css", "js", "ts", "tsx", "jsx", "sh", "rb",
            "py", "java", "kt", "m", "mm", "h", "hpp", "c", "cc", "cpp", "go", "rs"
        ]
        return supportedExtensions.contains(ext)
    }

    private func makeCodeSearchMatch(
        repositoryFullName: String,
        branch: String,
        query: String,
        queryTokens: [String],
        indexedFile: GitHubIndexedFile,
        sourceSHA: String,
        pathRelevanceScore: Int
    ) -> ScoredCodeSearchMatch? {
        let lowercasedContent = indexedFile.content.lowercased()
        let lowercasedQuery = query.lowercased()
        var matchRange = lowercasedContent.range(of: lowercasedQuery)
        let matchedTokenCount = queryTokens.filter { lowercasedContent.contains($0.lowercased()) }.count
        if matchRange == nil, !queryTokens.isEmpty,
           queryTokens.allSatisfy({ lowercasedContent.contains($0.lowercased()) }) {
            if let firstToken = queryTokens.first {
                matchRange = lowercasedContent.range(of: firstToken.lowercased())
            }
        }
        guard let matchRange else {
            guard matchedTokenCount > 0 else {
                return nil
            }
            guard let firstMatchedToken = queryTokens.first(where: { lowercasedContent.contains($0.lowercased()) }),
                  let tokenRange = lowercasedContent.range(of: firstMatchedToken.lowercased()) else {
                return nil
            }
            return makeCodeSearchMatch(
                repositoryFullName: repositoryFullName,
                branch: branch,
                queryTokens: queryTokens,
                indexedFile: indexedFile,
                sourceSHA: sourceSHA,
                pathRelevanceScore: pathRelevanceScore,
                resolvedMatchRange: tokenRange,
                matchedTokenCount: matchedTokenCount,
                exactPhraseMatched: false
            )
        }

        return makeCodeSearchMatch(
            repositoryFullName: repositoryFullName,
            branch: branch,
            queryTokens: queryTokens,
            indexedFile: indexedFile,
            sourceSHA: sourceSHA,
            pathRelevanceScore: pathRelevanceScore,
            resolvedMatchRange: matchRange,
            matchedTokenCount: matchedTokenCount,
            exactPhraseMatched: lowercasedContent.range(of: lowercasedQuery) != nil
        )
    }

    private func makeCodeSearchMatch(
        repositoryFullName: String,
        branch: String,
        queryTokens: [String],
        indexedFile: GitHubIndexedFile,
        sourceSHA: String,
        pathRelevanceScore: Int,
        resolvedMatchRange: Range<String.Index>,
        matchedTokenCount: Int,
        exactPhraseMatched: Bool
    ) -> ScoredCodeSearchMatch {
        let lowercasedContent = indexedFile.content.lowercased()
        let matchRange = resolvedMatchRange

        let utf16Lower = lowercasedContent.utf16
        let matchOffset = utf16Lower.distance(from: utf16Lower.startIndex, to: matchRange.lowerBound.samePosition(in: utf16Lower) ?? utf16Lower.startIndex)
        let lines = splitLines(indexedFile.content)
        var consumed = 0
        var matchLineIndex = 0
        for (index, line) in lines.enumerated() {
            let lineLength = line.utf16.count + 1
            if consumed + lineLength > matchOffset {
                matchLineIndex = index
                break
            }
            consumed += lineLength
        }

        let startLineIndex = max(0, matchLineIndex - 2)
        let endLineIndex = min(lines.count - 1, matchLineIndex + 2)
        let snippetLines = Array(lines[startLineIndex...endLineIndex])
        var score = pathRelevanceScore
        if exactPhraseMatched {
            score += 240
        }
        score += matchedTokenCount * 45
        if !queryTokens.isEmpty, matchedTokenCount == queryTokens.count {
            score += 140
        }

        return ScoredCodeSearchMatch(
            match: GitHubCodeSearchMatch(
                path: indexedFile.path,
                start_line: startLineIndex + 1,
                end_line: endLineIndex + 1,
                snippet: snippetLines.joined(separator: "\n"),
                anchor: GitHubCitationAnchor(
                    repository: repositoryFullName,
                    branch: branch,
                    path: indexedFile.path,
                    start_line: startLineIndex + 1,
                    end_line: endLineIndex + 1,
                    source_sha: indexedFile.sha ?? sourceSHA
                )
            ),
            score: score
        )
    }

    private struct ScoredCodeSearchMatch {
        var match: GitHubCodeSearchMatch
        var score: Int
    }

    private func summarizeChanges(_ changes: [GitHubFileChange]) -> String {
        changes
            .map { "\($0.operation.rawValue):\($0.path)" }
            .joined(separator: ", ")
    }

    private func shortSHA(_ sha: String) -> String {
        String(sha.prefix(12))
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private func elapsedMilliseconds(since startedAt: Date, until endAt: Date) -> Int {
        Int(endAt.timeIntervalSince(startedAt) * 1_000)
    }

    private func displayPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "/"
        }
        return path
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
            "commit_message": .string("Update config, tests, and release notes"),
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
                ]),
                .object([
                    "path": .string("Docs/ReleaseNotes.md"),
                    "operation": .string("update"),
                    "content": .string("# Release Notes\n\n- Added the new config version.\n")
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
            return ##"{"owner":"octo","repo":"demo","base_ref":"main","branch_name":"feature/update-config","commit_message":"Update config, tests, and release notes","changes":[{"path":"Sources/Config.swift","operation":"update","content":"struct Config {\n    let version = 2\n}\n"},{"path":"Tests/ConfigTests.swift","operation":"create","content":"import XCTest\n"},{"path":"Docs/ReleaseNotes.md","operation":"update","content":"# Release Notes\n\n- Added the new config version.\n"}]}"##
        case .selectedContext:
            return ##"{"branch_name":"feature/update-config","commit_message":"Update config, tests, and release notes","changes":[{"path":"Sources/Config.swift","operation":"update","content":"struct Config {\n    let version = 2\n}\n"},{"path":"Tests/ConfigTests.swift","operation":"create","content":"import XCTest\n"},{"path":"Docs/ReleaseNotes.md","operation":"update","content":"# Release Notes\n\n- Added the new config version.\n"}]}"##
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

    private var searchPathsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_search_paths",
            description: "Search indexed repository paths in the currently selected GitHub repository and branch. Use this first when the user refers to a file conceptually, such as 'message timestamp formatter', instead of rescanning guessed subtrees like src or Sources.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Conceptual or exact file/path query.")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of path matches to return (default 10, max 20).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))
    }

    private var searchCodeToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_search_code",
            description: "Search indexed code and text in the currently selected GitHub repository and branch. Returns matching snippets with file paths and line anchors.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Text query to search for in indexed files.")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of code matches to return (default 10, max 20).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))
    }

    private var getRepoTreeToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_repo_tree",
            description: "Recursively list nested paths in the currently selected GitHub repository and branch. Use this once at the start of a repo task to discover exact repo-relative file paths, then reuse the earlier tree result instead of rescanning the same subtree. If the task refers to a file conceptually, switch to github_search_paths instead of guessing more missing subtrees.",
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
            description: "Read the full content of a file from the currently selected GitHub repository and branch. Prefer this for small or medium files. If the result returns truncated=true, or if you need to inspect or append near the end of a large file, switch to github_get_file_tail or github_get_file_lines instead of rereading the same path.",
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

    private var getFileLinesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_file_lines",
            description: "Read a precise bounded line range from a file in the currently selected GitHub repository and branch. Prefer this for targeted edits, citations, or when you already know the approximate line window. Do not use it as a generic fallback for rereading an entire file.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path within the selected repository")
                    ]),
                    "start_line": .object([
                        "type": .string("integer"),
                        "description": .string("1-based inclusive starting line number.")
                    ]),
                    "end_line": .object([
                        "type": .string("integer"),
                        "description": .string("1-based inclusive ending line number.")
                    ])
                ]),
                "required": .array([
                    .string("path"),
                    .string("start_line"),
                    .string("end_line")
                ])
            ])
        ))
    }

    private var getFileTailToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_file_tail",
            description: "Read the last lines of a file from the currently selected GitHub repository and branch. Prefer this when appending comments, inspecting file endings, or recovering after github_get_file_content returned truncated=true for a large file.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path within the selected repository")
                    ]),
                    "max_lines": .object([
                        "type": .string("integer"),
                        "description": .string("Number of lines to return from the end of the file (default 80, max 300).")
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

    private var searchIssuesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_search_issues",
            description: "Search issues in the currently selected GitHub repository by text query.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Issue search query text.")
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

    private var searchPullRequestsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_search_pull_requests",
            description: "Search pull requests in the currently selected GitHub repository by text query.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Pull request search query text.")
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

    private var getPullRequestFilesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_pull_request_files",
            description: "List the changed files for a pull request in the currently selected GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "number": .object([
                        "type": .string("integer"),
                        "description": .string("Pull request number")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of changed files to return (max 100, default 100).")
                    ])
                ]),
                "required": .array([.string("number")])
            ])
        ))
    }

    private var getPullRequestDiffToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_get_pull_request_diff",
            description: "Read the unified diff for a pull request in the currently selected GitHub repository.",
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

    private var listBranchesToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_branches",
            description: "List branches in the currently selected GitHub repository.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of branches to return (max 100, default 100).")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var listCommitsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_list_commits",
            description: "List recent commits in the currently selected GitHub repository. You can optionally provide a branch or ref to scope the commit list.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Optional branch, tag, or commit to list commits from.")
                    ]),
                    "per_page": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of commits to return (max 30, default 10).")
                    ])
                ]),
                "required": .array([])
            ])
        ))
    }

    private var compareRefsToolForSelectedContext: ToolDefinition {
        ToolDefinition(function: FunctionDefinitionBody(
            name: "github_compare_refs",
            description: "Compare two refs in the currently selected GitHub repository and return commit/file diff metadata between them.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "base": .object([
                        "type": .string("string"),
                        "description": .string("Base branch, tag, or SHA.")
                    ]),
                    "head": .object([
                        "type": .string("string"),
                        "description": .string("Head branch, tag, or SHA.")
                    ])
                ]),
                "required": .array([.string("base"), .string("head")])
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
            description: "Commit file changes to a new branch from the currently selected GitHub base branch. Supports three operations per file: 'create' (new file), 'update' (replace an existing file — read it first with github_get_file_content or github_get_file_tail, then provide the complete modified content), and 'delete' (remove a file). One github_commit_file_changes call can update multiple files, and should include all requested edits in changes[] when possible. Do not send owner, repo, or base_ref here; the selected repository and base branch are already known for this chat. Put path, operation, and optional content inside each changes[] item, where each item represents one file. Requires explicit user approval before any write occurs.",
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
