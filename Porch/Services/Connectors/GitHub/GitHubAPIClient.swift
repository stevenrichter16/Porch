import Foundation

actor GitHubAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let baseURL = URL(string: "https://api.github.com")!
    private let token: String

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Search

    func searchRepositories(query: String, perPage: Int = 10) async throws -> GitHubSearchReposResponse {
        var components = URLComponents(url: baseURL.appending(path: "search/repositories"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "\(min(perPage, 30))")
        ]
        return try await perform(url: components.url!)
    }

    // MARK: - Repository Contents

    func getRepoContents(owner: String, repo: String, path: String = "", ref: String? = nil) async throws -> [GitHubContentItem] {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/contents/\(encodedPath)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let ref {
            components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        }
        return try await perform(url: components.url!)
    }

    func getFileContent(owner: String, repo: String, path: String, ref: String? = nil) async throws -> GitHubFileContent {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/contents/\(encodedPath)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let ref {
            components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        }
        return try await perform(url: components.url!)
    }

    // MARK: - Issues

    func listIssues(owner: String, repo: String, state: String = "open", perPage: Int = 10) async throws -> [GitHubIssue] {
        var components = URLComponents(url: baseURL.appending(path: "repos/\(owner)/\(repo)/issues"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "per_page", value: "\(min(perPage, 30))")
        ]
        return try await perform(url: components.url!)
    }

    func getIssue(owner: String, repo: String, number: Int) async throws -> GitHubIssue {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/issues/\(number)")
        return try await perform(url: url)
    }

    // MARK: - Pull Requests

    func listPullRequests(owner: String, repo: String, state: String = "open", perPage: Int = 10) async throws -> [GitHubPullRequest] {
        var components = URLComponents(url: baseURL.appending(path: "repos/\(owner)/\(repo)/pulls"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "per_page", value: "\(min(perPage, 30))")
        ]
        return try await perform(url: components.url!)
    }

    func getPullRequest(owner: String, repo: String, number: Int) async throws -> GitHubPullRequest {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/pulls/\(number)")
        return try await perform(url: url)
    }

    // MARK: - User

    func getAuthenticatedUser() async throws -> GitHubAuthenticatedUser {
        let url = baseURL.appending(path: "user")
        return try await perform(url: url)
    }

    // MARK: - Internal

    private func perform<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("Invalid response from GitHub API.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ConnectorError.apiError("GitHub API returned \(httpResponse.statusCode): \(body)")
        }

        return try decoder.decode(T.self, from: data)
    }
}
