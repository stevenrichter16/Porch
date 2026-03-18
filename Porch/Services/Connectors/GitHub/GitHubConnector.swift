import Foundation

final class GitHubConnector: Connector, @unchecked Sendable {
    let id = "github"
    let displayName = "GitHub"
    let iconSystemName = "chevron.left.forwardslash.chevron.right"

    private let keychain: KeychainStoreProtocol
    private let keychainAccount = "github-pat"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: KeychainStoreProtocol = KeychainStore()) {
        self.keychain = keychain
    }

    var isConfigured: Bool {
        guard let token = try? keychain.read(account: keychainAccount) else { return false }
        return token != nil && !(token?.isEmpty ?? true)
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
            getPullRequestTool
        ]
    }

    // MARK: - Execution

    func execute(toolName: String, arguments: String) async throws -> String {
        guard let token = try keychain.read(account: keychainAccount), !token.isEmpty else {
            throw ConnectorError.notConfigured("GitHub")
        }

        let client = GitHubAPIClient(token: token)
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
        default:
            throw ConnectorError.unknownTool(toolName)
        }
    }

    // MARK: - Tool Implementations

    private func executeSearchRepos(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var query: String; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let response = try await client.searchRepositories(query: args.query, perPage: args.per_page ?? 10)
        let result: [[String: String]] = response.items.map(\.summary)
        return try encodeResult(["total_count": response.total_count, "repositories": result])
    }

    private func executeGetRepoContents(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var path: String?; var ref: String? }
        let args = try decodeArgs(Args.self, from: argsData)
        let items = try await client.getRepoContents(owner: args.owner, repo: args.repo, path: args.path ?? "", ref: args.ref)
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
            // Truncate very large files to avoid overwhelming the model
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
            owner: args.owner, repo: args.repo,
            state: args.state ?? "open", perPage: args.per_page ?? 10
        )
        // Filter out pull requests from the issues endpoint
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

    private func executeListPullRequests(client: GitHubAPIClient, argsData: Data) async throws -> String {
        struct Args: Decodable { var owner: String; var repo: String; var state: String?; var per_page: Int? }
        let args = try decodeArgs(Args.self, from: argsData)
        let prs = try await client.listPullRequests(
            owner: args.owner, repo: args.repo,
            state: args.state ?? "open", perPage: args.per_page ?? 10
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

    // MARK: - Helpers

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
}
