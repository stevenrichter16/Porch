import Foundation

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
