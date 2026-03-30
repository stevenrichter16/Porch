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
            toolName: "github_commit_file_changes",
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

        let treeTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_get_repo_tree" }))
        let treeJSON = try definitionJSON(for: treeTool)
        let treeFunctionJSON = try XCTUnwrap(treeJSON["function"] as? [String: Any])
        let treeParameters = try XCTUnwrap(treeFunctionJSON["parameters"] as? [String: Any])
        let treePropertyMap = try XCTUnwrap(treeParameters["properties"] as? [String: Any])
        XCTAssertNil(treePropertyMap["owner"])
        XCTAssertNil(treePropertyMap["repo"])
        XCTAssertNotNil(treePropertyMap["path_prefix"])
        XCTAssertNotNil(treePropertyMap["entry_type"])
        XCTAssertNotNil(treePropertyMap["max_entries"])

        let pathSearchTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_search_paths" }))
        let pathSearchJSON = try definitionJSON(for: pathSearchTool)
        let pathSearchFunctionJSON = try XCTUnwrap(pathSearchJSON["function"] as? [String: Any])
        let pathSearchParameters = try XCTUnwrap(pathSearchFunctionJSON["parameters"] as? [String: Any])
        let pathSearchPropertyMap = try XCTUnwrap(pathSearchParameters["properties"] as? [String: Any])
        XCTAssertNotNil(pathSearchPropertyMap["query"])
        XCTAssertNotNil(pathSearchPropertyMap["max_results"])
        XCTAssertTrue((pathSearchFunctionJSON["description"] as? String)?.contains("conceptually") == true)

        let fileLinesTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_get_file_lines" }))
        let fileLinesJSON = try definitionJSON(for: fileLinesTool)
        let fileLinesFunctionJSON = try XCTUnwrap(fileLinesJSON["function"] as? [String: Any])
        let fileLinesParameters = try XCTUnwrap(fileLinesFunctionJSON["parameters"] as? [String: Any])
        let fileLinesPropertyMap = try XCTUnwrap(fileLinesParameters["properties"] as? [String: Any])
        XCTAssertNotNil(fileLinesPropertyMap["path"])
        XCTAssertNotNil(fileLinesPropertyMap["start_line"])
        XCTAssertNotNil(fileLinesPropertyMap["end_line"])
        let fileLinesDescription = try XCTUnwrap(fileLinesFunctionJSON["description"] as? String)
        XCTAssertTrue(fileLinesDescription.contains("bounded"))
        XCTAssertTrue(fileLinesDescription.contains("approximate"))
        XCTAssertTrue(fileLinesDescription.contains("generic fallback"))

        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_search_code" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_list_branches" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_list_commits" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_compare_refs" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_search_issues" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_search_pull_requests" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_get_pull_request_files" }))
        XCTAssertNotNil(tools.first(where: { $0.function.name == "github_get_pull_request_diff" }))

        let tailTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_get_file_tail" }))
        let tailJSON = try definitionJSON(for: tailTool)
        let tailFunctionJSON = try XCTUnwrap(tailJSON["function"] as? [String: Any])
        let tailParameters = try XCTUnwrap(tailFunctionJSON["parameters"] as? [String: Any])
        let tailPropertyMap = try XCTUnwrap(tailParameters["properties"] as? [String: Any])
        XCTAssertNil(tailPropertyMap["owner"])
        XCTAssertNil(tailPropertyMap["repo"])
        XCTAssertNotNil(tailPropertyMap["path"])
        XCTAssertNotNil(tailPropertyMap["max_lines"])
        let tailDescription = try XCTUnwrap(tailFunctionJSON["description"] as? String)
        XCTAssertTrue(tailDescription.contains("appending comments"))
        XCTAssertTrue(tailDescription.contains("github_get_file_content returned truncated=true"))

        let writeTool = try XCTUnwrap(tools.first(where: { $0.function.name == "github_commit_file_changes" }))
        let writeJSON = try definitionJSON(for: writeTool)
        let writeFunctionJSON = try XCTUnwrap(writeJSON["function"] as? [String: Any])
        let writeParameters = try XCTUnwrap(writeFunctionJSON["parameters"] as? [String: Any])
        let writePropertyMap = try XCTUnwrap(writeParameters["properties"] as? [String: Any])
        XCTAssertNil(writePropertyMap["owner"])
        XCTAssertNil(writePropertyMap["repo"])
        XCTAssertNil(writePropertyMap["base_ref"])
        XCTAssertEqual(writeParameters["additionalProperties"] as? Bool, false)

        let changesProperty = try XCTUnwrap(writePropertyMap["changes"] as? [String: Any])
        let changeItems = try XCTUnwrap(changesProperty["items"] as? [String: Any])
        XCTAssertEqual(changeItems["additionalProperties"] as? Bool, false)

        let changeProperties = try XCTUnwrap(changeItems["properties"] as? [String: Any])
        let operationProperty = try XCTUnwrap(changeProperties["operation"] as? [String: Any])
        let operationEnum = try XCTUnwrap(operationProperty["enum"] as? [String])
        XCTAssertEqual(operationEnum, ["create", "update", "delete"])

        let writeDescription = try XCTUnwrap(writeFunctionJSON["description"] as? String)
        XCTAssertTrue(writeDescription.contains("Do not send owner, repo, or base_ref"))
        XCTAssertTrue(writeDescription.contains("changes[]"))
        XCTAssertTrue(writeDescription.contains("One github_commit_file_changes call can update multiple files"))

        let examples = try XCTUnwrap(writeParameters["examples"] as? [[String: Any]])
        let example = try XCTUnwrap(examples.first)
        XCTAssertNil(example["owner"])
        XCTAssertNil(example["repo"])
        XCTAssertEqual(example["branch_name"] as? String, "feature/update-config")
        let exampleChanges = try XCTUnwrap(example["changes"] as? [[String: Any]])
        XCTAssertEqual(exampleChanges.count, 3)
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
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Feature.swift", "mode": "100644", "type": "blob", "sha": "feature-sha", "size": 11]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Feature.swift"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first(where: { $0.name == "ref" })?.value, "feature/work")
                return .data(body: try self.makeJSONData([
                    "name": "Feature.swift",
                    "path": "Sources/Feature.swift",
                    "sha": "feature-sha",
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

    func testContextBoundPathSearchFindsConceptualFilenameFromIndexedTree() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "main"
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Utilities/MessageTimestampFormatter.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": 300],
                        ["path": "Porch/Utilities/ChatTitleGenerator.swift", "mode": "100644", "type": "blob", "sha": "sha-2", "size": 200]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_search_paths",
            arguments: #"{"query":"message timestamp formatter"}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["path"] as? String, "Porch/Utilities/MessageTimestampFormatter.swift")
    }

    func testContextBoundPathSearchFiltersWeakMatchesForBroadConceptualQuery() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "main"
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": 200],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubModels.swift", "mode": "100644", "type": "blob", "sha": "sha-2", "size": 180],
                        ["path": "Porch/ViewModels/GitHubContextSelectionViewModel.swift", "mode": "100644", "type": "blob", "sha": "sha-3", "size": 175],
                        ["path": "Porch/ViewModels/ChatViewModel.swift", "mode": "100644", "type": "blob", "sha": "sha-4", "size": 220],
                        ["path": "Porch/Services/Connectors/ConnectorProtocol.swift", "mode": "100644", "type": "blob", "sha": "sha-8", "size": 110],
                        ["path": "Porch/Services/Connectors/WebSearch/WebSearchConnector.swift", "mode": "100644", "type": "blob", "sha": "sha-9", "size": 150],
                        ["path": "PorchTests/GitHubConnectorTests.swift", "mode": "100644", "type": "blob", "sha": "sha-10", "size": 250],
                        ["path": "Docs/GitHubConnectorGuide.md", "mode": "100644", "type": "blob", "sha": "sha-5", "size": 160],
                        ["path": "Porch/Assets.xcassets/Colors/Contents.json", "mode": "100644", "type": "blob", "sha": "sha-6", "size": 100],
                        ["path": "Porch/Utilities/MessageTimestampFormatter.swift", "mode": "100644", "type": "blob", "sha": "sha-7", "size": 140]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_search_paths",
            arguments: #"{"query":"connector state","max_results":10}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        let returnedPaths = results.compactMap { $0["path"] as? String }
        XCTAssertEqual(Set(returnedPaths.prefix(2)), Set([
            "Porch/Services/Connectors/GitHub/GitHubConnector.swift",
            "Porch/Services/Connectors/GitHub/GitHubModels.swift"
        ]))
        XCTAssertFalse(returnedPaths.prefix(2).contains("Docs/GitHubConnectorGuide.md"))
        XCTAssertFalse(returnedPaths.prefix(2).contains("Porch/Assets.xcassets/Colors/Contents.json"))
        XCTAssertFalse(returnedPaths.prefix(2).contains("Porch/Services/Connectors/ConnectorProtocol.swift"))
        XCTAssertFalse(returnedPaths.prefix(2).contains("Porch/Services/Connectors/WebSearch/WebSearchConnector.swift"))
        XCTAssertFalse(returnedPaths.prefix(2).contains("PorchTests/GitHubConnectorTests.swift"))
    }

    func testContextBoundCodeSearchPrioritizesSourceFilesOverDocsAndAssets() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "main"
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": 220],
                        ["path": "Porch/Services/Connectors/GitHub/GitHubModels.swift", "mode": "100644", "type": "blob", "sha": "sha-2", "size": 210],
                        ["path": "Porch/Services/Connectors/ConnectorProtocol.swift", "mode": "100644", "type": "blob", "sha": "sha-5", "size": 160],
                        ["path": "Porch/Services/Connectors/WebSearch/WebSearchConnector.swift", "mode": "100644", "type": "blob", "sha": "sha-6", "size": 180],
                        ["path": "PorchTests/GitHubConnectorTests.swift", "mode": "100644", "type": "blob", "sha": "sha-7", "size": 200],
                        ["path": "Docs/GitHubConnectorState.md", "mode": "100644", "type": "blob", "sha": "sha-3", "size": 180],
                        ["path": "Porch/Assets.xcassets/Colors/Contents.json", "mode": "100644", "type": "blob", "sha": "sha-4", "size": 120]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubConnector.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubConnector.swift",
                    "path": "Porch/Services/Connectors/GitHub/GitHubConnector.swift",
                    "sha": "sha-1",
                    "content": Data("""
                    final class GitHubConnector {
                        let connectorState = "GitHub connector state"
                    }
                    """.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 220
                ]))

            case ("GET", "/repos/octo/demo/contents/Porch/Services/Connectors/GitHub/GitHubModels.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubModels.swift",
                    "path": "Porch/Services/Connectors/GitHub/GitHubModels.swift",
                    "sha": "sha-2",
                    "content": Data("""
                    struct GitHubStateModel {
                        let connectorDescription = "GitHub connector state"
                    }
                    """.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 210
                ]))

            case ("GET", "/repos/octo/demo/contents/Porch/Services/Connectors/ConnectorProtocol.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "ConnectorProtocol.swift",
                    "path": "Porch/Services/Connectors/ConnectorProtocol.swift",
                    "sha": "sha-5",
                    "content": Data("""
                    protocol ConnectorProtocol {
                        func execute() -> String
                    }
                    """.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 160
                ]))

            case ("GET", "/repos/octo/demo/contents/Porch/Services/Connectors/WebSearch/WebSearchConnector.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "WebSearchConnector.swift",
                    "path": "Porch/Services/Connectors/WebSearch/WebSearchConnector.swift",
                    "sha": "sha-6",
                    "content": Data("""
                    final class WebSearchConnector {
                        let stateDescription = "web search state"
                    }
                    """.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 180
                ]))

            case ("GET", "/repos/octo/demo/contents/PorchTests/GitHubConnectorTests.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubConnectorTests.swift",
                    "path": "PorchTests/GitHubConnectorTests.swift",
                    "sha": "sha-7",
                    "content": Data("""
                    final class GitHubConnectorTests {
                        func testConnectorState() {}
                    }
                    """.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 200
                ]))

            case ("GET", "/repos/octo/demo/contents/Docs/GitHubConnectorState.md"):
                return .data(body: try self.makeJSONData([
                    "name": "GitHubConnectorState.md",
                    "path": "Docs/GitHubConnectorState.md",
                    "sha": "sha-3",
                    "content": Data("# GitHub connector state\nDocumentation about connector state.\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 180
                ]))

            case ("GET", "/repos/octo/demo/contents/Porch/Assets.xcassets/Colors/Contents.json"):
                return .data(body: try self.makeJSONData([
                    "name": "Contents.json",
                    "path": "Porch/Assets.xcassets/Colors/Contents.json",
                    "sha": "sha-4",
                    "content": Data("{\"label\":\"GitHub connector state\"}".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 120
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_search_code",
            arguments: #"{"query":"GitHub connector state","max_results":4}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        let returnedPaths = results.compactMap { $0["path"] as? String }
        XCTAssertEqual(Set(returnedPaths.prefix(2)), Set([
            "Porch/Services/Connectors/GitHub/GitHubConnector.swift",
            "Porch/Services/Connectors/GitHub/GitHubModels.swift"
        ]))
        XCTAssertFalse(returnedPaths.contains("Docs/GitHubConnectorState.md"))
        XCTAssertFalse(returnedPaths.contains("Porch/Assets.xcassets/Colors/Contents.json"))
        XCTAssertFalse(returnedPaths.contains("Porch/Services/Connectors/ConnectorProtocol.swift"))
        XCTAssertFalse(returnedPaths.contains("Porch/Services/Connectors/WebSearch/WebSearchConnector.swift"))
        XCTAssertFalse(returnedPaths.contains("PorchTests/GitHubConnectorTests.swift"))
    }

    func testContextBoundCodeSearchValidatesHeadOnlyOncePerInvocation() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "main"
        )

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/main"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/main",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/One.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": 100],
                        ["path": "Sources/Two.swift", "mode": "100644", "type": "blob", "sha": "sha-2", "size": 100],
                        ["path": "Sources/Three.swift", "mode": "100644", "type": "blob", "sha": "sha-3", "size": 100]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/One.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "One.swift",
                    "path": "Sources/One.swift",
                    "sha": "sha-1",
                    "content": Data("let connector = \"state one\"\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 100
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Two.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Two.swift",
                    "path": "Sources/Two.swift",
                    "sha": "sha-2",
                    "content": Data("let connector = \"state two\"\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 100
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Three.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Three.swift",
                    "path": "Sources/Three.swift",
                    "sha": "sha-3",
                    "content": Data("let connector = \"state three\"\n".utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": 100
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        _ = try await connector.execute(
            toolName: "github_search_code",
            arguments: #"{"query":"connector state","max_results":3}"#,
            context: context
        )

        let refRequests = MockURLProtocol.capturedRequests.filter {
            $0.url?.path == "/repos/octo/demo/git/ref/heads/main"
        }
        XCTAssertEqual(refRequests.count, 1)
    }

    func testContextBoundFileLinesReturnsTargetedLineRangeWithAnchor() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )
        let content = ["one", "two", "three", "four", "five"].joined(separator: "\n")

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Feature.swift", "mode": "100644", "type": "blob", "sha": "sha-1", "size": content.count]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Feature.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Feature.swift",
                    "path": "Sources/Feature.swift",
                    "sha": "sha-1",
                    "content": Data(content.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": content.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_file_lines",
            arguments: #"{"path":"Sources/Feature.swift","start_line":2,"end_line":4}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["content"] as? String, "two\nthree\nfour")
        let anchor = try XCTUnwrap(payload["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["path"] as? String, "Sources/Feature.swift")
        XCTAssertEqual(anchor["start_line"] as? Int, 2)
        XCTAssertEqual(anchor["end_line"] as? Int, 4)
    }

    func testContextBoundPullRequestDiffReturnsTruncatedUnifiedDiff() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "main"
        )
        let diff = String(repeating: "+ line\n", count: 3000)

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }
            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/pulls/42"):
                return .data(body: Data(diff.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_pull_request_diff",
            arguments: #"{"number":42}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["number"] as? Int, 42)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertTrue((payload["diff"] as? String)?.contains("[Diff truncated]") == true)
    }

    func testContextBoundReadTruncatesReturnedContentAtTwelveThousandCharacters() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )
        let longContent = String(repeating: "a", count: 12_500)

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Feature.swift", "mode": "100644", "type": "blob", "sha": "feature-sha", "size": longContent.count]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Feature.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Feature.swift",
                    "path": "Sources/Feature.swift",
                    "sha": "feature-sha",
                    "content": Data(longContent.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": longContent.count
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

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["path"] as? String, "Sources/Feature.swift")
        XCTAssertEqual(payload["size"] as? String, String(longContent.count))
        XCTAssertEqual(payload["truncated"] as? String, "true")
        XCTAssertNil(payload["name"])

        let returnedContent = try XCTUnwrap(payload["content"] as? String)
        XCTAssertTrue(returnedContent.hasPrefix(String(repeating: "a", count: 12_000)))
        XCTAssertTrue(returnedContent.contains("[Content truncated at 12000 characters]"))
    }

    func testContextBoundFileTailReturnsExpectedLineWindow() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )
        let content = ["one", "two", "three", "four", "five"].joined(separator: "\n")

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Feature.swift", "mode": "100644", "type": "blob", "sha": "feature-sha", "size": content.count]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Feature.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Feature.swift",
                    "path": "Sources/Feature.swift",
                    "sha": "feature-sha",
                    "content": Data(content.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": content.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_file_tail",
            arguments: #"{"path":"Sources/Feature.swift","max_lines":2}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["path"] as? String, "Sources/Feature.swift")
        XCTAssertEqual(payload["size"] as? Int, content.count)
        XCTAssertEqual(payload["start_line"] as? Int, 4)
        XCTAssertEqual(payload["end_line"] as? Int, 5)
        XCTAssertEqual(payload["line_count"] as? Int, 2)
        XCTAssertEqual(payload["content"] as? String, "four\nfive")
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }

    func testContextBoundFileTailTruncatesLargeTailPayload() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )
        let lines = (1...220).map { _ in String(repeating: "a", count: 80) }
        let content = lines.joined(separator: "\n")

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Large.swift", "mode": "100644", "type": "blob", "sha": "large-sha", "size": content.count]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Large.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Large.swift",
                    "path": "Sources/Large.swift",
                    "sha": "large-sha",
                    "content": Data(content.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": content.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_file_tail",
            arguments: #"{"path":"Sources/Large.swift","max_lines":200}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        let returnedContent = try XCTUnwrap(payload["content"] as? String)
        XCTAssertEqual(payload["path"] as? String, "Sources/Large.swift")
        XCTAssertEqual(payload["end_line"] as? Int, 220)
        XCTAssertEqual(payload["line_count"] as? Int, 200)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(returnedContent.count, 12_000)
        XCTAssertTrue(returnedContent.hasSuffix(String(repeating: "a", count: 80)))
    }

    func testContextBoundFileTailClampsOversizedMaxLines() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )
        let lines = (1...350).map { "line-\($0)" }
        let content = lines.joined(separator: "\n")

        MockURLProtocol.setRequestHandler { request in
            guard let url = request.url else {
                return .data(statusCode: 500)
            }

            switch (request.httpMethod, url.path) {
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": ["sha": "base-commit", "type": "commit"]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": ["sha": "base-tree"]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Sources/Large.swift", "mode": "100644", "type": "blob", "sha": "sha-large", "size": content.count]
                    ]
                ]))

            case ("GET", "/repos/octo/demo/contents/Sources/Large.swift"):
                return .data(body: try self.makeJSONData([
                    "name": "Large.swift",
                    "path": "Sources/Large.swift",
                    "sha": "sha-large",
                    "content": Data(content.utf8).base64EncodedString(),
                    "encoding": "base64",
                    "size": content.count
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_file_tail",
            arguments: #"{"path":"Sources/Large.swift","max_lines":301}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["line_count"] as? Int, 300)
    }

    func testContextBoundRecursiveTreeUsesSelectedRepoAndBranch() async throws {
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
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

            case ("GET", "/repos/octo/demo/git/commits/base-commit"):
                return .data(body: try self.makeJSONData([
                    "sha": "base-commit",
                    "tree": [
                        "sha": "base-tree"
                    ]
                ]))

            case ("GET", "/repos/octo/demo/git/trees/base-tree"):
                let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(queryItems.first(where: { $0.name == "recursive" })?.value, "1")
                return .data(body: try self.makeJSONData([
                    "sha": "base-tree",
                    "truncated": false,
                    "tree": [
                        ["path": "Docs", "mode": "040000", "type": "tree"],
                        ["path": "Docs/Guide.md", "mode": "100644", "type": "blob", "size": 128],
                        ["path": "Scripts/build.sh", "mode": "100755", "type": "blob", "size": 64],
                        ["path": "Vendor/Submodule", "mode": "160000", "type": "commit"],
                        ["path": "link-to-guide", "mode": "120000", "type": "blob", "size": 8]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_repo_tree",
            arguments: "{}",
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["repository"] as? String, "octo/demo")
        XCTAssertEqual(payload["branch"] as? String, "feature/work")
        XCTAssertEqual(payload["returned_count"] as? Int, 5)
        XCTAssertEqual(payload["truncated"] as? Bool, false)

        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["path"] as? String }, [
            "Docs",
            "Docs/Guide.md",
            "Scripts/build.sh",
            "Vendor/Submodule",
            "link-to-guide"
        ])
        XCTAssertEqual(entries[0]["kind"] as? String, "directory")
        XCTAssertEqual(entries[1]["kind"] as? String, "file")
        XCTAssertEqual(entries[3]["kind"] as? String, "submodule")
        XCTAssertEqual(entries[4]["kind"] as? String, "symlink")
    }

    func testContextBoundRecursiveTreeFiltersPrefixTypeAndTruncation() async throws {
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
            case ("GET", "/repos/octo/demo/git/ref/heads/feature/work"):
                return .data(body: try self.makeJSONData([
                    "ref": "refs/heads/feature/work",
                    "object": [
                        "sha": "base-commit",
                        "type": "commit"
                    ]
                ]))

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
                    "tree": [
                        ["path": "Sources", "mode": "040000", "type": "tree"],
                        ["path": "Sources/App.swift", "mode": "100644", "type": "blob", "size": 10],
                        ["path": "Sources/Feature.swift", "mode": "100644", "type": "blob", "size": 20],
                        ["path": "Tests/Test.swift", "mode": "100644", "type": "blob", "size": 30]
                    ]
                ]))

            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(url)")
                return .data(statusCode: 500)
            }
        }

        let result = try await connector.execute(
            toolName: "github_get_repo_tree",
            arguments: #"{"path_prefix":"Sources/","entry_type":"files","max_entries":1}"#,
            context: context
        )

        let payload = try resultJSON(from: result)
        XCTAssertEqual(payload["path_prefix"] as? String, "Sources")
        XCTAssertEqual(payload["returned_count"] as? Int, 1)
        XCTAssertEqual(payload["total_matching_count"] as? Int, 2)
        XCTAssertEqual(payload["truncated"] as? Bool, true)

        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["path"] as? String, "Sources/App.swift")
        XCTAssertEqual(entries[0]["kind"] as? String, "file")
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
            toolName: "github_commit_file_changes",
            arguments: #"{"commit_message":"Add the generated file","changes":[{"path":"Sources/NewFile.swift","operation":"create","content":"print(\"Hello from Porch\")\n"}]}"#,
            context: context
        )

        XCTAssertEqual(request.resolvedBaseRef, "feature/work")
    }

    func testContextBoundWriteRejectsTopLevelPathWithTargetedError() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
                arguments: #"{"commit_message":"Add tests","path":"PorchTests/WebSearchConnectorTests.swift","changes":[{"path":"PorchTests/WebSearchConnectorTests.swift","operation":"create","content":"import XCTest\n"}]}"#,
                context: context
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Do not place path, operation, or content at the top level"))
            XCTAssertTrue(error.localizedDescription.contains("Example:"))
        }
    }

    func testContextBoundWriteRejectsRepoIdentityKeysWithTargetedError() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
                arguments: #"{"owner":"octo","repo":"demo","base_ref":"main","commit_message":"Add tests","changes":[{"path":"PorchTests/WebSearchConnectorTests.swift","operation":"create","content":"import XCTest\n"}]}"#,
                context: context
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Do not send owner, repo, or base_ref"))
            XCTAssertTrue(error.localizedDescription.contains("selected GitHub repository and base branch are already known"))
        }
    }

    func testContextBoundWriteRejectsChangesObjectInsteadOfArray() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
                arguments: #"{"commit_message":"Add tests","changes":{"path":"PorchTests/WebSearchConnectorTests.swift","operation":"create","content":"import XCTest\n"}}"#,
                context: context
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changes must be an array"))
        }
    }

    func testContextBoundWriteRejectsInvalidOperationValue() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
                arguments: #"{"commit_message":"Add tests","changes":[{"path":"PorchTests/WebSearchConnectorTests.swift","operation":"replace","content":"import XCTest\n"}]}"#,
                context: context
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changes[0].operation must be one of create, update, or delete"))
        }
    }

    func testContextBoundWriteMalformedJSONExplainsEscaping() async throws {
        let connector = try makeConnector()
        let context = GitHubChatContext(
            owner: "octo",
            repo: "demo",
            fullName: "octo/demo",
            branch: "feature/work"
        )

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
                arguments: "{\"commit_message\":\"Add tests\",\"changes\":[{\"path\":\"PorchTests/WebSearchConnectorTests.swift\",\"operation\":\"create\",\"content\":\"import XCTest\n\"}]}",
                context: context
            )
            XCTFail("Expected invalid arguments error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Arguments must be valid JSON"))
            XCTAssertTrue(error.localizedDescription.contains("JSON-escaped strings"))
        }
    }

    func testPrepareWriteRequestRejectsUnsafePathBeforeNetworkPreflight() async throws {
        let connector = try makeConnector()

        do {
            _ = try await connector.prepareWriteRequest(
                toolName: "github_commit_file_changes",
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
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return GitHubConnector(
            keychain: keychain,
            session: TestSessionFactory.makeSession(),
            syncCoordinator: GitHubSyncCoordinator(
                store: GitHubIndexStore(directoryURL: indexDirectory),
                nowProvider: { now }
            ),
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

    private func resultJSON(from string: String) throws -> [String: Any] {
        let data = try XCTUnwrap(string.data(using: .utf8))
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
