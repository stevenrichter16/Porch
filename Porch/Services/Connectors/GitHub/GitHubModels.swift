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
