import Foundation

actor GitHubAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let baseURL = URL(string: "https://api.github.com")!
    private let token: String

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
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

    func getRepository(owner: String, repo: String) async throws -> GitHubRepositoryMetadata {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)")
        return try await perform(url: url)
    }

    func listAccessibleRepositories(page: Int = 1, perPage: Int = 100) async throws -> [GitHubRepository] {
        var components = URLComponents(
            url: baseURL.appending(path: "user/repos"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "visibility", value: "all"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "\(min(perPage, 100))"),
            URLQueryItem(name: "page", value: "\(max(page, 1))")
        ]
        return try await perform(url: components.url!)
    }

    func listBranches(owner: String, repo: String, perPage: Int = 100) async throws -> [GitHubBranchSummary] {
        var components = URLComponents(
            url: baseURL.appending(path: "repos/\(owner)/\(repo)/branches"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(min(perPage, 100))")
        ]
        return try await perform(url: components.url!)
    }

    func getRef(owner: String, repo: String, ref: String) async throws -> GitHubRef {
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/ref/\(encodedRef)")
        return try await perform(url: url)
    }

    func getCommit(owner: String, repo: String, sha: String) async throws -> GitHubCommitObject {
        let encodedSHA = sha.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sha
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/commits/\(encodedSHA)")
        return try await perform(url: url)
    }

    func getTree(owner: String, repo: String, sha: String, recursive: Bool = false) async throws -> GitHubTreeResponse {
        let encodedSHA = sha.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sha
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/trees/\(encodedSHA)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if recursive {
            components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        }
        return try await perform(url: components.url!)
    }

    func createBlob(owner: String, repo: String, content: String) async throws -> GitHubBlobResponse {
        struct RequestBody: Encodable {
            var content: String
            var encoding: String = "utf-8"
        }

        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/blobs")
        return try await perform(url: url, method: "POST", body: RequestBody(content: content))
    }

    func createTree(owner: String, repo: String, requestBody: GitHubCreateTreeRequest) async throws -> GitHubCreatedTree {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/trees")
        return try await perform(url: url, method: "POST", body: requestBody)
    }

    func createCommit(owner: String, repo: String, message: String, treeSHA: String, parentCommitSHA: String) async throws -> GitHubCreatedCommit {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/commits")
        let body = GitHubCreateCommitRequest(message: message, tree: treeSHA, parents: [parentCommitSHA])
        return try await perform(url: url, method: "POST", body: body)
    }

    func createRef(owner: String, repo: String, branchName: String, commitSHA: String) async throws -> GitHubCreatedRef {
        let url = baseURL.appending(path: "repos/\(owner)/\(repo)/git/refs")
        let body = GitHubCreateRefRequest(ref: "refs/heads/\(branchName)", sha: commitSHA)
        return try await perform(url: url, method: "POST", body: body)
    }

    // MARK: - Internal

    private func perform<T: Decodable>(url: URL) async throws -> T {
        let request = makeRequest(url: url, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func perform<Body: Encodable, T: Decodable>(url: URL, method: String, body: Body) async throws -> T {
        let requestBody = try encoder.encode(body)
        var request = makeRequest(url: url, method: method)
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubAPIError.httpStatus(httpResponse.statusCode, body)
        }
    }
}
