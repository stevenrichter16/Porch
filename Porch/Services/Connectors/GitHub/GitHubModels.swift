import Foundation
import OSLog

// MARK: - Search Repositories

struct GitHubSearchReposResponse: Decodable {
    var total_count: Int
    var items: [GitHubRepository]
}

struct GitHubRepository: Decodable {
    var full_name: String
    var description: String?
    var html_url: String
    var stargazers_count: Int
    var language: String?
    var updated_at: String?
    var open_issues_count: Int
    var fork: Bool
    var `private`: Bool

    var summary: [String: String] {
        var result: [String: String] = [
            "full_name": full_name,
            "html_url": html_url,
            "stars": "\(stargazers_count)",
            "open_issues": "\(open_issues_count)"
        ]
        if let description { result["description"] = description }
        if let language { result["language"] = language }
        if let updated_at { result["updated_at"] = updated_at }
        return result
    }
}

// MARK: - Repository Contents

struct GitHubContentItem: Decodable {
    var name: String
    var path: String
    var type: String  // "file" or "dir"
    var size: Int?
    var html_url: String?

    var summary: [String: String] {
        var result: [String: String] = [
            "name": name,
            "path": path,
            "type": type
        ]
        if let size { result["size"] = "\(size)" }
        return result
    }
}

// MARK: - File Content

struct GitHubFileContent: Decodable {
    var name: String
    var path: String
    var sha: String?
    var content: String?
    var encoding: String?
    var size: Int
    var html_url: String?

    var decodedContent: String? {
        guard let content, encoding == "base64" else { return content }
        let cleaned = content.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Issues

struct GitHubIssue: Decodable {
    var number: Int
    var title: String
    var state: String
    var body: String?
    var html_url: String
    var user: GitHubUser?
    var labels: [GitHubLabel]?
    var created_at: String
    var updated_at: String
    var comments: Int?
    var pull_request: PullRequestRef?

    struct PullRequestRef: Decodable {
        var url: String?
    }

    var isPullRequest: Bool {
        pull_request != nil
    }

    var summary: [String: String] {
        var result: [String: String] = [
            "number": "\(number)",
            "title": title,
            "state": state,
            "html_url": html_url,
            "created_at": created_at,
            "updated_at": updated_at
        ]
        if let body {
            let truncated = body.count > 500 ? String(body.prefix(500)) + "..." : body
            result["body"] = truncated
        }
        if let user { result["author"] = user.login }
        if let labels, !labels.isEmpty {
            result["labels"] = labels.map(\.name).joined(separator: ", ")
        }
        if let comments { result["comments"] = "\(comments)" }
        return result
    }
}

struct GitHubUser: Decodable {
    var login: String
    var html_url: String?
}

struct GitHubLabel: Decodable {
    var name: String
    var color: String?
}

// MARK: - Pull Requests

struct GitHubPullRequest: Decodable {
    var number: Int
    var title: String
    var state: String
    var body: String?
    var html_url: String
    var user: GitHubUser?
    var head: GitHubBranch?
    var base: GitHubBranch?
    var merged: Bool?
    var mergeable: Bool?
    var created_at: String
    var updated_at: String
    var comments: Int?

    struct GitHubBranch: Decodable {
        var ref: String
        var label: String?
    }

    var summary: [String: String] {
        var result: [String: String] = [
            "number": "\(number)",
            "title": title,
            "state": state,
            "html_url": html_url,
            "created_at": created_at,
            "updated_at": updated_at
        ]
        if let body {
            let truncated = body.count > 500 ? String(body.prefix(500)) + "..." : body
            result["body"] = truncated
        }
        if let user { result["author"] = user.login }
        if let head { result["head"] = head.ref }
        if let base { result["base"] = base.ref }
        if let merged { result["merged"] = "\(merged)" }
        return result
    }
}

// MARK: - Authenticated User

struct GitHubAuthenticatedUser: Decodable {
    var login: String
    var name: String?
    var html_url: String
}

struct GitHubChatContext: Codable, Equatable, Sendable {
    var owner: String
    var repo: String
    var fullName: String
    var branch: String

    var repositoryLabel: String {
        fullName.isEmpty ? "\(owner)/\(repo)" : fullName
    }
}

// MARK: - Repository Metadata / Git Data API

enum GitHubAPIError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, String)

    var statusCode: Int? {
        switch self {
        case .invalidResponse:
            nil
        case .httpStatus(let statusCode, _):
            statusCode
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from GitHub API."
        case .httpStatus(let statusCode, let body):
            if body.isEmpty {
                return "GitHub API returned \(statusCode)."
            }
            return "GitHub API returned \(statusCode): \(body)"
        }
    }
}

struct GitHubRepositoryMetadata: Decodable {
    var owner: GitHubUser
    var name: String
    var full_name: String
    var default_branch: String
    var html_url: String
    var `private`: Bool
}

struct GitHubBranchSummary: Decodable, Identifiable, Equatable, Sendable {
    struct BranchCommit: Decodable, Equatable, Sendable {
        var sha: String
    }

    var name: String
    var commit: BranchCommit?

    var id: String { name }
}

struct GitHubRef: Decodable {
    struct RefObject: Decodable {
        var sha: String
        var type: String
    }

    var ref: String
    var object: RefObject
}

struct GitHubCommitObject: Decodable {
    struct Tree: Decodable {
        var sha: String
    }

    var sha: String
    var tree: Tree
}

struct GitHubTreeResponse: Decodable {
    struct Entry: Decodable, Equatable, Sendable {
        var path: String
        var mode: String?
        var type: String
        var sha: String?
        var size: Int?
    }

    var sha: String
    var truncated: Bool?
    var tree: [Entry]
}

enum GitHubRepoTreeEntryKind: String, Codable, Equatable, Sendable {
    case file
    case directory
    case symlink
    case submodule
}

struct GitHubRepoTreeEntry: Encodable, Equatable, Sendable {
    var path: String
    var kind: GitHubRepoTreeEntryKind
    var size: Int?
}

struct GitHubRepoTreeResult: Encodable, Equatable, Sendable {
    var repository: String
    var branch: String
    var path_prefix: String?
    var returned_count: Int
    var total_matching_count: Int
    var truncated: Bool
    var entries: [GitHubRepoTreeEntry]
    var advisory: String?
}

struct GitHubFileTailResult: Encodable, Equatable, Sendable {
    var path: String
    var size: Int
    var start_line: Int
    var end_line: Int
    var line_count: Int
    var content: String
    var truncated: Bool
    var anchor: GitHubCitationAnchor?
}

struct GitHubBlobResponse: Decodable {
    var sha: String
}

struct GitHubCreateTreeRequest: Encodable {
    struct Entry: Encodable, Equatable, Sendable {
        var path: String
        var mode: String
        var type: String
        var sha: String?
        var isDelete: Bool

        init(path: String, mode: String = "100644", type: String = "blob", sha: String?, isDelete: Bool = false) {
            self.path = path
            self.mode = mode
            self.type = type
            self.sha = sha
            self.isDelete = isDelete
        }

        enum CodingKeys: String, CodingKey {
            case path
            case mode
            case type
            case sha
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(mode, forKey: .mode)
            try container.encode(type, forKey: .type)
            if isDelete {
                try container.encodeNil(forKey: .sha)
            } else {
                try container.encode(sha, forKey: .sha)
            }
        }
    }

    var base_tree: String
    var tree: [Entry]
}

struct GitHubCreatedTree: Decodable {
    var sha: String
}

struct GitHubCreateCommitRequest: Encodable {
    var message: String
    var tree: String
    var parents: [String]
}

struct GitHubCreatedCommit: Decodable {
    var sha: String
    var html_url: String?
}

struct GitHubCreateRefRequest: Encodable {
    var ref: String
    var sha: String
}

struct GitHubCreatedRef: Decodable {
    var ref: String
    var object: GitHubRef.RefObject
}

// MARK: - Write Tool Types

enum GitHubFileOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case create
    case update
    case delete
}

struct GitHubFileChange: Codable, Equatable, Sendable {
    var path: String
    var operation: GitHubFileOperation
    var content: String?
}

struct GitHubDiffPreview: Identifiable, Equatable, Sendable {
    var id: String { path }

    var path: String
    var operation: GitHubFileOperation
    var diffText: String
}

struct GitHubWriteRequest: Equatable, Sendable {
    var owner: String
    var repo: String
    var repositoryFullName: String
    var repositoryHTMLURL: String
    var resolvedBaseRef: String
    var proposedBranchName: String
    var commitMessage: String
    var baseCommitSHA: String
    var baseTreeSHA: String
    var changes: [GitHubFileChange]
    var diffPreviews: [GitHubDiffPreview]
}

struct PendingGitHubWriteApproval: Identifiable, Equatable, Sendable {
    let id: UUID
    var owner: String
    var repo: String
    var repositoryFullName: String
    var repositoryHTMLURL: String
    var resolvedBaseRef: String
    var proposedBranchName: String
    var commitMessage: String
    var changes: [GitHubFileChange]
    var diffPreviews: [GitHubDiffPreview]

    init(
        id: UUID = UUID(),
        owner: String,
        repo: String,
        repositoryFullName: String,
        repositoryHTMLURL: String,
        resolvedBaseRef: String,
        proposedBranchName: String,
        commitMessage: String,
        changes: [GitHubFileChange],
        diffPreviews: [GitHubDiffPreview]
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.repositoryFullName = repositoryFullName
        self.repositoryHTMLURL = repositoryHTMLURL
        self.resolvedBaseRef = resolvedBaseRef
        self.proposedBranchName = proposedBranchName
        self.commitMessage = commitMessage
        self.changes = changes
        self.diffPreviews = diffPreviews
    }

    init(request: GitHubWriteRequest, id: UUID = UUID()) {
        self.init(
            id: id,
            owner: request.owner,
            repo: request.repo,
            repositoryFullName: request.repositoryFullName,
            repositoryHTMLURL: request.repositoryHTMLURL,
            resolvedBaseRef: request.resolvedBaseRef,
            proposedBranchName: request.proposedBranchName,
            commitMessage: request.commitMessage,
            changes: request.changes,
            diffPreviews: request.diffPreviews
        )
    }

    var createdCount: Int {
        changes.filter { $0.operation == .create }.count
    }

    var updatedCount: Int {
        changes.filter { $0.operation == .update }.count
    }

    var deletedCount: Int {
        changes.filter { $0.operation == .delete }.count
    }
}

struct GitHubWriteResult: Encodable, Equatable, Sendable {
    var status: String
    var owner: String
    var repo: String
    var base_ref: String
    var branch_name: String
    var branch_ref: String
    var branch_url: String
    var commit_message: String
    var commit_sha: String
    var commit_url: String?
    var changed_files: Int
    var created_count: Int
    var updated_count: Int
    var deleted_count: Int
}

struct GitHubWriteCancelledResult: Encodable, Equatable, Sendable {
    var status: String = "cancelled"
    var reason: String
}

// MARK: - Search / Compare / Diff

struct GitHubCitationAnchor: Encodable, Equatable, Sendable {
    var repository: String
    var branch: String
    var path: String
    var start_line: Int?
    var end_line: Int?
    var source_sha: String?
}

struct GitHubPathSearchMatch: Encodable, Equatable, Sendable {
    var path: String
    var kind: GitHubRepoTreeEntryKind
    var score: Int
    var anchor: GitHubCitationAnchor
}

struct GitHubPathSearchResult: Encodable, Equatable, Sendable {
    var repository: String
    var branch: String
    var query: String
    var returned_count: Int
    var total_matching_count: Int
    var results: [GitHubPathSearchMatch]
}

struct GitHubCodeSearchMatch: Encodable, Equatable, Sendable {
    var path: String
    var start_line: Int
    var end_line: Int
    var snippet: String
    var anchor: GitHubCitationAnchor
}

struct GitHubCodeSearchResult: Encodable, Equatable, Sendable {
    var repository: String
    var branch: String
    var query: String
    var returned_count: Int
    var searched_files: Int
    var results: [GitHubCodeSearchMatch]
}

enum GitHubSearchNormalizer {
    private static let stopWords: Set<String> = ["github"]
    private static let combinedTokenMap: [[String]: String] = [
        ["git", "hub"]: "github",
        ["view", "model"]: "viewmodel",
        ["view", "models"]: "viewmodels",
        ["xc", "assets"]: "xcassets"
    ]

    static func tokenize(_ value: String) -> [String] {
        let expanded = expandCamelCase(in: value)
        let rawTokens = expanded
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else {
            return []
        }
        return combineSpecialTokens(in: rawTokens)
    }

    static func normalizeQueryFamily(_ rawQuery: String) -> String? {
        let allTokens = tokenize(rawQuery)
        guard !allTokens.isEmpty else {
            return nil
        }

        let meaningfulTokens = allTokens.filter { !stopWords.contains($0) }
        let normalizedTokens = meaningfulTokens.isEmpty ? allTokens : meaningfulTokens
        let dedupedTokens = Array(Set(normalizedTokens)).sorted()
        guard !dedupedTokens.isEmpty else {
            return nil
        }
        return dedupedTokens.joined(separator: " ")
    }

    static func normalizedSearchString(_ value: String) -> String {
        tokenize(value).joined(separator: " ")
    }

    private static func expandCamelCase(in value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else {
            return value
        }

        var result = ""
        result.reserveCapacity(value.count + value.count / 4)

        for index in scalars.indices {
            let scalar = scalars[index]
            if index > scalars.startIndex {
                let previous = scalars[index - 1]
                let next = index < scalars.index(before: scalars.endIndex) ? scalars[index + 1] : nil

                let shouldInsertBoundary =
                    (CharacterSet.lowercaseLetters.contains(previous) || CharacterSet.decimalDigits.contains(previous)) &&
                        CharacterSet.uppercaseLetters.contains(scalar) ||
                    CharacterSet.uppercaseLetters.contains(previous) &&
                        CharacterSet.uppercaseLetters.contains(scalar) &&
                        next.map { CharacterSet.lowercaseLetters.contains($0) } == true

                if shouldInsertBoundary {
                    result.append(" ")
                }
            }

            result.append(String(scalar))
        }

        return result
    }

    private static func combineSpecialTokens(in tokens: [String]) -> [String] {
        guard tokens.count >= 2 else {
            return tokens
        }

        var combined: [String] = []
        var index = 0

        while index < tokens.count {
            var matchedComposite: String?
            var matchedLength = 0

            for (pattern, composite) in combinedTokenMap where pattern.count <= tokens.count - index {
                if Array(tokens[index..<(index + pattern.count)]) == pattern, pattern.count > matchedLength {
                    matchedComposite = composite
                    matchedLength = pattern.count
                }
            }

            if let matchedComposite {
                combined.append(matchedComposite)
                index += matchedLength
            } else {
                combined.append(tokens[index])
                index += 1
            }
        }

        return combined
    }
}

struct GitHubFileLinesResult: Encodable, Equatable, Sendable {
    var path: String
    var size: Int
    var start_line: Int
    var end_line: Int
    var line_count: Int
    var content: String
    var truncated: Bool
    var anchor: GitHubCitationAnchor
}

struct GitHubCommitSummary: Decodable, Sendable {
    struct CommitDetail: Decodable, Sendable {
        struct CommitAuthor: Decodable, Sendable {
            var name: String
            var date: String
        }

        var message: String
        var author: CommitAuthor?
    }

    var sha: String
    var html_url: String?
    var commit: CommitDetail
    var author: GitHubUser?

    var summary: [String: String] {
        var result: [String: String] = [
            "sha": sha,
            "message": commit.message,
        ]
        if let html_url {
            result["html_url"] = html_url
        }
        if let author {
            result["author"] = author.login
        }
        if let date = commit.author?.date {
            result["date"] = date
        }
        return result
    }
}

struct GitHubCompareResponse: Decodable, Sendable {
    struct ComparedCommit: Decodable, Sendable {
        var sha: String
        var html_url: String?
        var commit: GitHubCommitSummary.CommitDetail
    }

    struct ComparedFile: Decodable, Sendable {
        var filename: String
        var status: String
        var additions: Int?
        var deletions: Int?
        var changes: Int?
        var patch: String?
    }

    var status: String
    var ahead_by: Int
    var behind_by: Int
    var total_commits: Int
    var html_url: String?
    var files: [ComparedFile]?
    var commits: [ComparedCommit]
}

struct GitHubCompareResult: Encodable, Equatable, Sendable {
    var base: String
    var head: String
    var status: String
    var ahead_by: Int
    var behind_by: Int
    var total_commits: Int
    var html_url: String?
    var commits: [[String: String]]
    var files: [[String: String]]
}

struct GitHubSearchIssuesResponse: Decodable {
    var total_count: Int
    var items: [GitHubIssue]
}

struct GitHubPullRequestFile: Decodable, Equatable, Sendable {
    var filename: String
    var status: String
    var additions: Int
    var deletions: Int
    var changes: Int
    var patch: String?

    var summary: [String: String] {
        var result: [String: String] = [
            "filename": filename,
            "status": status,
            "additions": "\(additions)",
            "deletions": "\(deletions)",
            "changes": "\(changes)"
        ]
        if let patch {
            result["patch"] = patch
        }
        return result
    }
}

struct GitHubPullRequestDiffResult: Encodable, Equatable, Sendable {
    var number: Int
    var diff: String
    var truncated: Bool
}

struct GitHubBranchListResult: Encodable, Equatable, Sendable {
    var branches: [[String: String]]
}

struct GitHubCommitListResult: Encodable, Equatable, Sendable {
    var commits: [[String: String]]
}

// MARK: - Local Index / Sync

struct GitHubIndexedTreeEntry: Codable, Equatable, Sendable {
    var path: String
    var kind: GitHubRepoTreeEntryKind
    var sha: String?
    var size: Int?
}

struct GitHubIndexedFile: Codable, Equatable, Sendable {
    var path: String
    var sha: String?
    var size: Int
    var content: String
    var updatedAt: Date
}

struct GitHubIndexedRepository: Codable, Equatable, Sendable {
    var repository: String
    var owner: String
    var repo: String
    var branch: String
    var headSHA: String
    var lastSyncedAt: Date
    var treeEntries: [GitHubIndexedTreeEntry]
    var filesByPath: [String: GitHubIndexedFile]
}

struct GitHubSyncStatus: Equatable, Sendable {
    var repository: String
    var branch: String
    var headSHA: String
    var lastSyncedAt: Date
    var indexedPathCount: Int
    var indexedContentCount: Int
}

actor GitHubIndexStore {
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directoryURL: URL? = nil) {
        let fileManager = FileManager.default
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = baseDirectory
                .appendingPathComponent("Porch", isDirectory: true)
                .appendingPathComponent("GitHubIndex", isDirectory: true)
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    func loadRepository(owner: String, repo: String, branch: String) throws -> GitHubIndexedRepository? {
        let url = try repositoryURL(owner: owner, repo: repo, branch: branch)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(GitHubIndexedRepository.self, from: data)
    }

    func saveRepository(_ repository: GitHubIndexedRepository) throws {
        let url = try repositoryURL(owner: repository.owner, repo: repository.repo, branch: repository.branch)
        let data = try encoder.encode(repository)
        try data.write(to: url, options: [.atomic])
    }

    private func repositoryURL(owner: String, repo: String, branch: String) throws -> URL {
        try ensureDirectoryExists()
        let slug = [owner, repo, branch]
            .map(Self.sanitizePathComponent)
            .joined(separator: "__")
        return directoryURL.appendingPathComponent("\(slug).json", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.reduce(into: "") { partialResult, scalar in
            if allowed.contains(scalar) {
                partialResult.append(String(scalar))
            } else {
                partialResult.append("_")
            }
        }
    }
}

actor GitHubSyncCoordinator {
    private static let logger = Logger(subsystem: "steven.Porch", category: "GitHubSyncCoordinator")
    private let store: GitHubIndexStore
    private let nowProvider: @Sendable () -> Date

    init(
        store: GitHubIndexStore = GitHubIndexStore(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.nowProvider = nowProvider
    }

    func ensureRepositoryIndex(
        owner: String,
        repo: String,
        branch: String,
        repositoryFullName: String,
        client: GitHubAPIClient,
        validatedRepository: GitHubIndexedRepository? = nil
    ) async throws -> GitHubIndexedRepository {
        let startedAt = Date()

        do {
            if let validatedRepository,
               validatedRepository.owner == owner,
               validatedRepository.repo == repo,
               validatedRepository.branch == branch,
               validatedRepository.repository == repositoryFullName {
                Self.logger.debug("GitHub execution validation cache hit for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) head=\(Self.shortSHA(validatedRepository.headSHA), privacy: .public) treeEntries=\(validatedRepository.treeEntries.count, privacy: .public) fileCacheEntries=\(validatedRepository.filesByPath.count, privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)")
                return validatedRepository
            }

            let headRef = try await client.getRef(owner: owner, repo: repo, ref: "heads/\(branch)")
            let afterHeadRef = Date()
            let cachedRepository = try await store.loadRepository(owner: owner, repo: repo, branch: branch)
            if let cached = cachedRepository,
               cached.headSHA == headRef.object.sha,
               !cached.treeEntries.isEmpty {
                Self.logger.debug("GitHub index cache hit for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) head=\(Self.shortSHA(headRef.object.sha), privacy: .public) treeEntries=\(cached.treeEntries.count, privacy: .public) fileCacheEntries=\(cached.filesByPath.count, privacy: .public) refMs=\(Self.elapsedMilliseconds(since: startedAt, until: afterHeadRef), privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)")
                return cached
            }

            let commit = try await client.getCommit(owner: owner, repo: repo, sha: headRef.object.sha)
            let afterCommit = Date()
            let tree = try await client.getTree(owner: owner, repo: repo, sha: commit.tree.sha, recursive: true)
            let afterTree = Date()
            let indexedEntries = tree.tree.compactMap { entry -> GitHubIndexedTreeEntry? in
                guard !entry.path.isEmpty else { return nil }
                guard let kind = Self.mapTreeEntryKind(entry) else { return nil }
                return GitHubIndexedTreeEntry(
                    path: entry.path,
                    kind: kind,
                    sha: entry.sha,
                    size: entry.size
                )
            }
            .sorted { $0.path < $1.path }

            let cachedFiles = cachedRepository?.filesByPath ?? [:]
            let repository = GitHubIndexedRepository(
                repository: repositoryFullName,
                owner: owner,
                repo: repo,
                branch: branch,
                headSHA: headRef.object.sha,
                lastSyncedAt: nowProvider(),
                treeEntries: indexedEntries,
                filesByPath: cachedFiles
            )
            try await store.saveRepository(repository)
            Self.logger.notice("GitHub index refresh for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) head=\(Self.shortSHA(headRef.object.sha), privacy: .public) treeEntries=\(indexedEntries.count, privacy: .public) retainedFileCacheEntries=\(cachedFiles.count, privacy: .public) refMs=\(Self.elapsedMilliseconds(since: startedAt, until: afterHeadRef), privacy: .public) commitMs=\(Self.elapsedMilliseconds(since: afterHeadRef, until: afterCommit), privacy: .public) treeMs=\(Self.elapsedMilliseconds(since: afterCommit, until: afterTree), privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)")
            return repository
        } catch {
            Self.logger.error("GitHub index load failed for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) after \(Self.elapsedMilliseconds(since: startedAt), privacy: .public)ms: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func syncStatus(
        owner: String,
        repo: String,
        branch: String
    ) async throws -> GitHubSyncStatus? {
        guard let repository = try await store.loadRepository(owner: owner, repo: repo, branch: branch) else {
            return nil
        }

        return GitHubSyncStatus(
            repository: repository.repository,
            branch: repository.branch,
            headSHA: repository.headSHA,
            lastSyncedAt: repository.lastSyncedAt,
            indexedPathCount: repository.treeEntries.count,
            indexedContentCount: repository.filesByPath.count
        )
    }

    func readTextFile(
        owner: String,
        repo: String,
        branch: String,
        repositoryFullName: String,
        path: String,
        client: GitHubAPIClient
    ) async throws -> GitHubIndexedFile {
        let startedAt = Date()
        let repository = try await ensureRepositoryIndex(
            owner: owner,
            repo: repo,
            branch: branch,
            repositoryFullName: repositoryFullName,
            client: client
        )
        let (indexedFile, _) = try await readTextFile(
            from: repository,
            owner: owner,
            repo: repo,
            branch: branch,
            repositoryFullName: repositoryFullName,
            path: path,
            client: client,
            startedAt: startedAt
        )
        return indexedFile
    }

    func readTextFile(
        from repository: GitHubIndexedRepository,
        owner: String,
        repo: String,
        branch: String,
        repositoryFullName: String,
        path: String,
        client: GitHubAPIClient
    ) async throws -> (file: GitHubIndexedFile, repository: GitHubIndexedRepository) {
        try await readTextFile(
            from: repository,
            owner: owner,
            repo: repo,
            branch: branch,
            repositoryFullName: repositoryFullName,
            path: path,
            client: client,
            startedAt: Date()
        )
    }

    private func readTextFile(
        from repository: GitHubIndexedRepository,
        owner: String,
        repo: String,
        branch: String,
        repositoryFullName: String,
        path: String,
        client: GitHubAPIClient,
        startedAt: Date
    ) async throws -> (file: GitHubIndexedFile, repository: GitHubIndexedRepository) {
        do {
            let normalizedPath = Self.normalizeRepoPath(path)
            let entry = repository.treeEntries.first(where: { $0.path == normalizedPath })
            if let cached = repository.filesByPath[normalizedPath],
               cached.sha == entry?.sha {
                Self.logger.debug("GitHub indexed file cache hit for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) path=\(normalizedPath, privacy: .public) size=\(cached.size, privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)")
                return (cached, repository)
            }

            if entry == nil {
                Self.logger.notice("GitHub indexed file cache miss for unknown path \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) path=\(normalizedPath, privacy: .public)")
            }

            let beforeFetch = Date()
            let file = try await client.getFileContent(owner: owner, repo: repo, path: normalizedPath, ref: branch)
            guard let decoded = file.decodedContent else {
                throw ConnectorError.apiError("GitHub file content could not be decoded as UTF-8 text.")
            }

            let indexedFile = GitHubIndexedFile(
                path: file.path,
                sha: file.sha ?? entry?.sha,
                size: file.size,
                content: decoded,
                updatedAt: nowProvider()
            )
            var updatedRepository = repository
            updatedRepository.filesByPath[file.path] = indexedFile
            try await store.saveRepository(updatedRepository)
            Self.logger.notice("GitHub indexed file cache miss fetched live for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) path=\(normalizedPath, privacy: .public) size=\(file.size, privacy: .public) fetchMs=\(Self.elapsedMilliseconds(since: beforeFetch), privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)")
            return (indexedFile, updatedRepository)
        } catch {
            Self.logger.error("GitHub indexed file read failed for \(repositoryFullName, privacy: .public) branch=\(branch, privacy: .public) path=\(path, privacy: .public) after \(Self.elapsedMilliseconds(since: startedAt), privacy: .public)ms: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func normalizeRepoPath(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func mapTreeEntryKind(_ entry: GitHubTreeResponse.Entry) -> GitHubRepoTreeEntryKind? {
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

    private static func shortSHA(_ sha: String) -> String {
        String(sha.prefix(12))
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private static func elapsedMilliseconds(since startedAt: Date, until endAt: Date) -> Int {
        Int(endAt.timeIntervalSince(startedAt) * 1_000)
    }
}
