import XCTest
@testable import Porch

final class GitHubConnectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testPrepareWriteRequestFallsBackToDefaultBranchWhenMainMissing() async throws {
        let connector = try makeConnector(now: Date(timeIntervalSince1970: 1_710_000_000))

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
                    "default_branch": "develop",
                    "html_url": "https://github.com/octo/demo",
                    "private": false
                ]))

            case ("GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("GET", "/repos/octo/demo/git/ref/heads/develop"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/develop",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("GET", let path) where path.hasPrefix("/repos/octo/demo/git/ref/heads/porch/"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": []
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let request = try await connector.prepareWriteRequest(
            toolName: "github_create_branch_and_commit_changes",
            arguments: writeArgumentsJSON()
        )

        XCTAssertEqual(request.resolvedBaseRef, "develop")
        XCTAssertEqual(request.changes.map(\.path), ["Sources/NewFile.swift"])
        XCTAssertTrue(request.proposedBranchName.hasPrefix("porch/add-the-generated-file-"))
    }

    func testToolDefinitionsForMissingContextAreEmpty() throws {
        let connector = try makeConnector()
        XCTAssertTrue(connector.toolDefinitions(for: nil).isEmpty)
    }

    func testToolDefinitionsForSelectedContextOmitRepoIdentityParameters() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        let tools = connector.toolDefinitions(for: context)
        XCTAssertFalse(tools.contains(where: { $0.function.name == "github_search_repos" }))

        let contentsTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_get_repo_contents" }))
        let contentsJSON = try definitionJSON(for: contentsTool)
        let functionJSON = try XCTUnwrap(contentsJSON["function"] as? [String: Any])
        let properties = try XCTUnwrap(functionJSON["parameters"] as? [String: Any])
        let propertyMap = try XCTUnwrap(properties["properties"] as? [String: Any])
        XCTAssertNil(propertyMap["owner"])
        XCTAssertNil(propertyMap["repo"])
        XCTAssertNotNil(propertyMap["path"])

        let writeTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_create_branch_and_commit_changes" }))
        let writeJSON = try definitionJSON(for: writeTool)
        let writeFunctionJSON = try XCTUnwrap(writeJSON["function"] as? [String: Any])
        let writeParameters = try XCTUnwrap(writeFunctionJSON["parameters"] as? [String: Any])
        let writePropertyMap = try XCTUnwrap(writeParameters["properties"] as? [String: Any])
        XCTAssertNil(writePropertyMap["owner"])
        XCTAssertNil(writePropertyMap["repo"])
        XCTAssertNil(writePropertyMap["base_ref"])
    }

    func testContextBoundReadUsesSelectedRepoAndBranch() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/contents/Sources/Feature.swift"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first(where: { $0.name == "ref" })?.value, "feature/work")
                return .data(body: try self.makeJSONData([
                    "name": "Feature.swift",
                    "path": "Sources/Feature.swift",
                    "content": Data("print(\"hi\")".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 11
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_file_content",
            arguments: #"{"path":"Sources/Feature.swift"}"#,
            context: context
        )

        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.contains("\"error\""))
    }

    func testContextBoundWriteUsesSelectedBranchAsBaseRef() async throws {
        let connector = try makeConnector(now: Date(timeIntervalSince1970: 1_710_000_000))
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
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

            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("GET", let path) where path.hasPrefix("/repos/octo/demo/git/ref/heads/porch/"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": []
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let request = try await connector.prepareWriteRequest(
            toolName: "github_create_branch_and_commit_changes",
            arguments: #"{"commit_message":"Add the generated file","changes":[{"path":"Sources/NewFile.swift","operation":"create","content":"print(\"Hello from Porch\")\n"}]}"#,
            context: context
        )

        XCTAssertEqual(request.resolvedBaseRef, "feature/work")
    }

    func testPrepareWriteRequestRejectsUnsafePathBeforeNetworkPreflight() async throws {
        let connector = try makeConnector()

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_create_branch_and_commit_changes",
                arguments: """
                {"owner":"octo","repo":"demo","commit_message":"Bad path","changes":[{"path":"../Secrets.txt","operation":"create","content":"nope"}]}
                """
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Paths must not contain '..'"))
        }
    }

    func testExecuteApprovedWriteCreatesOneCommitAndBranchRef() async throws {
        let connector = try makeConnector()
        let request = GitHubWriteRequest(
            owner: "octo",
            repo: "demo",
            repositoryFullName: "octo/demo",
            repositoryHTMLURL: "https://github.com/octo/demo",
            resolvedBaseRef: "main",
            proposedBranchName: "porch/generated-branch",
            commitMessage: "Add the generated file",
            baseCommitSHA: "base-commit",
            baseTreeSHA: "base-tree",
            changes: [
                GitHubFileChange(path: "Sources/NewFile.swift", operation: .create, content: "print(\"hello\")\n"),
                GitHubFileChange(path: "README.md", operation: .delete, content: nil)
            ],
            diffPreviews: []
        )

        let blobCounter = LockedCounter()

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/approved"):
                return .data(statusCode: 404, body: Data("{\"message\":\"Not Found\"}".utf8))

            case ("POST", "/repos/octo/demo/git/blobs"):
                let blobIndex = blobCounter.next() + 1
                return .data(body: try self.makeJSONData([
                    "sha": "blob-\(blobIndex)"
                ]))

            case ("POST", "/repos/octo/demo/git/trees"):
                return .data(body: try self.makeJSONData([
                    "sha": "tree-2"
                ]))

            case ("POST", "/repos/octo/demo/git/commits"):
                return .data(body: try self.makeJSONData([
                    "sha": "commit-2",
                    "html_url": "https://github.com/octo/demo/commit/commit-2"
                ]))

            case ("POST", "/repos/octo/demo/git/refs"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/approved",
                    "object": [
                        "sha": "commit-2",
                        "type": "commit"
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.executeApprovedWrite(
            request,
            branchName: "feature/approved",
            commitMessage: "Apply the reviewed GitHub change"
        )

        XCTAssertEqual(result.status, "success")
        XCTAssertEqual(result.branch_name, "feature/approved")
        XCTAssertEqual(result.commit_sha, "commit-2")
        XCTAssertEqual(result.changed_files, 2)

        let treeRequest = try XCTUnwrap(
            MockURLProtocol.capturedRequests.first(where: { $0.url?.path == "/repos/octo/demo/git/trees" })
        )
        let treeBody = try requestBodyJSON(for: treeRequest)
        let treeEntries = try XCTUnwrap(treeBody["tree"] as? [[String: Any]])
        XCTAssertEqual(treeEntries.count, 2)
        XCTAssertEqual(treeEntries[0]["path"] as? String, "Sources/NewFile.swift")
        XCTAssertTrue(treeEntries[1]["sha"] is NSNull)

        let commitRequest = try XCTUnwrap(
            MockURLProtocol.capturedRequests.first(where: { $0.url?.path == "/repos/octo/demo/git/commits" })
        )
        let commitBody = try requestBodyJSON(for: commitRequest)
        XCTAssertEqual(commitBody["message"] as? String, "Apply the reviewed GitHub change")
        XCTAssertEqual(commitBody["parents"] as? [String], ["base-commit"])

        let refRequest = try XCTUnwrap(
            MockURLProtocol.capturedRequests.first(where: { $0.url?.path == "/repos/octo/demo/git/refs" })
        )
        let refBody = try requestBodyJSON(for: refRequest)
        XCTAssertEqual(refBody["ref"] as? String, "refs/heads/feature/approved")
    }

    private func makeConnector(now: Date = Date()) throws -> GitHubConnector {
        let keychain = MemoryKeychainStore()
        try keychain.save("github-secret", account: "github-pat")
        return GitHubConnector(
            keychain: keychain,
            session: TestSessionFactory.makeSession(),
            nowProvider: { now }
        )
    }

    private func writeArgumentsJSON() -> String {
        """
        {"owner":"octo","repo":"demo","commit_message":"Add the generated file","changes":[{"path":"Sources/NewFile.swift","operation":"create","content":"print(\\"Hello from Porch\\")\\n"}]}
        """
    }

    private func makeJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func requestBodyJSON(for request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func definitionJSON(for definition: ToolDefinition) throws -> [String: Any] {
        let data = try JSONEncoder().encode(definition)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
