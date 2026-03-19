import XCTest
@testable import Porch

@MainActor
final class GitHubContextSelectionViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testAccessibleRepositoriesLoadAndInlineBranchSelectionUpdatesDraftContext() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/user/repos"):
                return .data(body: try self.makeJSONData([
                    [
                        "full_name": "octo/demo",
                        "description": "Demo repo",
                        "html_url": "https://github.com/octo/demo",
                        "stargazers_count": 42,
                        "language": "Swift",
                        "updated_at": "2026-03-18T00:00:00Z",
                        "open_issues_count": 1,
                        "fork": false,
                        "private": false
                    ]
                ]))

            case ("GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "develop",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("GET", "/repos/octo/demo/branches"):
                return .data(body: try self.makeJSONData([
                    ["name": "develop", "commit": ["sha": "sha-1"]],
                    ["name": "main", "commit": ["sha": "sha-2"]]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadAccessibleRepositoriesIfNeeded()

        let repository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first)
        XCTAssertEqual(repository.full_name, "octo/demo")

        await viewModel.toggleRepositoryExpansion(repository)

        XCTAssertEqual(viewModel.expandedRepositoryFullName, "octo/demo")
        XCTAssertEqual(viewModel.branches(for: repository).map(\.name), ["develop", "main"])
        XCTAssertNil(viewModel.selectedContextDraft)
        XCTAssertFalse(viewModel.canSave)

        let branch = try XCTUnwrap(viewModel.branches(for: repository).first)
        viewModel.selectBranch(branch, for: repository)

        XCTAssertEqual(viewModel.selectedContextDraft?.fullName, "octo/demo")
        XCTAssertEqual(viewModel.selectedContextDraft?.branch, "develop")
        XCTAssertTrue(viewModel.canSave)
        XCTAssertTrue(viewModel.isBranchSelected(branch, for: repository))
    }

    func testExpandingSecondRepositoryCollapsesTheFirst() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/user/repos"):
                return .data(body: try self.makeJSONData([
                    [
                        "full_name": "octo/demo",
                        "description": "Demo repo",
                        "html_url": "https://github.com/octo/demo",
                        "stargazers_count": 42,
                        "language": "Swift",
                        "updated_at": "2026-03-18T00:00:00Z",
                        "open_issues_count": 1,
                        "fork": false,
                        "private": false
                    ],
                    [
                        "full_name": "acme/infrastructure",
                        "description": "Infra repo",
                        "html_url": "https://github.com/acme/infrastructure",
                        "stargazers_count": 10,
                        "language": "HCL",
                        "updated_at": "2026-03-17T00:00:00Z",
                        "open_issues_count": 0,
                        "fork": false,
                        "private": true
                    ]
                ]))

            case ("GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "develop",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("GET", "/repos/octo/demo/branches"):
                return .data(body: try self.makeJSONData([
                    ["name": "develop", "commit": ["sha": "sha-1"]]
                ]))

            case ("GET", "/repos/acme/infrastructure"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "acme"],
                    "name": "infrastructure",
                    "full_name": "acme/infrastructure",
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/infrastructure",
                    "private": true
                ]))

            case ("GET", "/repos/acme/infrastructure/branches"):
                return .data(body: try self.makeJSONData([
                    ["name": "main", "commit": ["sha": "sha-2"]]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadAccessibleRepositoriesIfNeeded()
        let firstRepository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first(where: { $0.full_name == "octo/demo" }))
        let secondRepository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first(where: { $0.full_name == "acme/infrastructure" }))

        await viewModel.toggleRepositoryExpansion(firstRepository)
        XCTAssertTrue(viewModel.isRepositoryExpanded(firstRepository))

        await viewModel.toggleRepositoryExpansion(secondRepository)
        XCTAssertFalse(viewModel.isRepositoryExpanded(firstRepository))
        XCTAssertTrue(viewModel.isRepositoryExpanded(secondRepository))
        XCTAssertEqual(viewModel.expandedRepositoryFullName, "acme/infrastructure")
    }

    func testLocalSearchFiltersLoadedAccessibleRepositories() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/user/repos"):
                return .data(body: try self.makeJSONData([
                    [
                        "full_name": "octo/demo",
                        "description": "Swift client",
                        "html_url": "https://github.com/octo/demo",
                        "stargazers_count": 42,
                        "language": "Swift",
                        "updated_at": "2026-03-18T00:00:00Z",
                        "open_issues_count": 1,
                        "fork": false,
                        "private": false
                    ],
                    [
                        "full_name": "acme/infrastructure",
                        "description": "Terraform infra",
                        "html_url": "https://github.com/acme/infrastructure",
                        "stargazers_count": 10,
                        "language": "HCL",
                        "updated_at": "2026-03-17T00:00:00Z",
                        "open_issues_count": 0,
                        "fork": false,
                        "private": true
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadAccessibleRepositoriesIfNeeded()

        viewModel.searchQuery = "swift"
        XCTAssertEqual(viewModel.filteredAvailableRepositories.map(\.full_name), ["octo/demo"])

        viewModel.searchQuery = "infra"
        XCTAssertEqual(viewModel.filteredAvailableRepositories.map(\.full_name), ["acme/infrastructure"])
    }

    func testManualRepositoryLoadEntersInlineBranchFlowAndValidatesManualBranch() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "main",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("GET", "/repos/octo/demo/branches"):
                return .data(body: try self.makeJSONData([
                    ["name": "main", "commit": ["sha": "sha-1"]]
                ]))

            case ("GET", "/repos/octo/demo/git/ref/heads/release/candidate"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/release/candidate",
                    "object": [
                        "sha": "sha-release",
                        "type": "commit"
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        viewModel.ownerInput = "octo"
        viewModel.repoInput = "demo"
        await viewModel.loadManualRepository()

        let repository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first(where: { $0.full_name == "octo/demo" }))
        XCTAssertEqual(viewModel.expandedRepositoryFullName, "octo/demo")
        XCTAssertEqual(viewModel.branches(for: repository).map(\.name), ["main"])
        XCTAssertNil(viewModel.selectedContextDraft)

        viewModel.expandedManualBranchInput = "release/candidate"
        await viewModel.validateExpandedManualBranch()

        XCTAssertEqual(viewModel.selectedContextDraft?.fullName, "octo/demo")
        XCTAssertEqual(viewModel.selectedContextDraft?.branch, "release/candidate")
        XCTAssertTrue(viewModel.canSave)
    }

    func testInitialContextAutoExpandsSavedRepositoryAndHighlightsInvalidBranch() async throws {
        let viewModel = try makeViewModel(
            initialContext: GitHubChatContext(
                owner: "octo",
                repo: "demo",
                fullName: "octo/demo",
                branch: "missing-branch"
            )
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo"):
                return .data(body: try self.makeJSONData([
                    "owner": ["login": "octo"],
                    "name": "demo",
                    "full_name": "octo/demo",
                    "default_branch": "main",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("GET", "/repos/octo/demo/branches"):
                return .data(body: try self.makeJSONData([
                    ["name": "main", "commit": ["sha": "sha-1"]]
                ]))

            case ("GET", "/repos/octo/demo/git/ref/heads/missing-branch"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadInitialContextIfNeeded()

        let repository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first(where: { $0.full_name == "octo/demo" }))
        XCTAssertEqual(viewModel.expandedRepositoryFullName, "octo/demo")
        XCTAssertEqual(viewModel.selectedBranchSummary(for: repository), "missing-branch")
        XCTAssertTrue(viewModel.selectedBranchNeedsAttention(for: repository))
        XCTAssertEqual(viewModel.expandedManualBranchInput, "missing-branch")
        XCTAssertEqual(viewModel.expandedBranchValidationMessage, "Branch missing-branch was not found.")
        XCTAssertNil(viewModel.selectedContextDraft)
        XCTAssertFalse(viewModel.canSave)
    }

    func testBranchLoadingFailureIsTrackedPerExpandedRepository() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/user/repos"):
                return .data(body: try self.makeJSONData([
                    [
                        "full_name": "octo/demo",
                        "description": "Demo repo",
                        "html_url": "https://github.com/octo/demo",
                        "stargazers_count": 42,
                        "language": "Swift",
                        "updated_at": "2026-03-18T00:00:00Z",
                        "open_issues_count": 1,
                        "fork": false,
                        "private": false
                    ]
                ]))

            case ("GET", "/repos/octo/demo"):
                return .data(statusCode: 500, body: Data("{\"message\":\"Server Error\"}".utf8))

            case ("GET", "/repos/octo/demo/branches"):
                return .data(statusCode: 500, body: Data("{\"message\":\"Server Error\"}".utf8))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadAccessibleRepositoriesIfNeeded()
        let repository = try XCTUnwrap(viewModel.filteredAvailableRepositories.first)
        await viewModel.toggleRepositoryExpansion(repository)

        XCTAssertEqual(viewModel.expandedRepositoryFullName, "octo/demo")
        XCTAssertFalse(viewModel.branchLoadError(for: repository)?.isEmpty ?? true)
    }

    func testAccessibleRepositoryLoadingFailurePublishesRetryableError() async throws {
        let viewModel = try makeViewModel()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/user/repos"):
                return .data(statusCode: 500, body: Data("{\"message\":\"Server Error\"}".utf8))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        await viewModel.loadAccessibleRepositoriesIfNeeded()

        XCTAssertTrue(viewModel.availableRepositories.isEmpty)
        XCTAssertFalse(viewModel.repoListErrorMessage?.isEmpty ?? true)
    }

    private func makeViewModel(initialContext: GitHubChatContext? = nil) throws -> GitHubContextSelectionViewModel {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        return GitHubContextSelectionViewModel(
            initialContext: initialContext,
            keychain: keychain,
            session: TestSessionFactory.makeSession()
        )
    }

    private func makeJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
