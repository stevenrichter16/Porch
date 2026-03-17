import SwiftData
import XCTest
@testable import Porch

@MainActor
final class SettingsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testValidateAndSavePersistsNormalizedServerModelsAndApiKey() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "http://macbook.local:1234/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return .data(body: try self.makeModelsResponse([
                ["id": "z-model", "owned_by": "local"],
                ["id": "a-model", "owned_by": "local"]
            ]))
        }

        harness.viewModel.baseURL = "macbook.local:1234"
        harness.viewModel.apiKey = "secret"

        let didValidate = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )

        XCTAssertTrue(didValidate)
        XCTAssertEqual(harness.viewModel.validationState, .valid)
        XCTAssertEqual(harness.viewModel.selectedModelID, "a-model")
        XCTAssertEqual(harness.settings.activeBaseURL, "http://macbook.local:1234/v1")
        XCTAssertEqual(harness.settings.defaultModelID, "a-model")
        XCTAssertEqual(harness.settings.availableModels.map(\.id), ["a-model", "z-model"])
        XCTAssertEqual(harness.settings.validationState, .valid)
        XCTAssertEqual(harness.keychain.storedValue(for: "active-server-api-key"), "secret")
    }

    func testValidateAndSaveFailsWhenNoModelsAreReturned() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setRequestHandler { _ in
            .data(body: try self.makeModelsResponse([]))
        }

        harness.viewModel.baseURL = "http://server.test:8080"
        let didValidate = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )

        XCTAssertFalse(didValidate)
        XCTAssertEqual(harness.viewModel.validationState, .invalid)
        XCTAssertEqual(harness.viewModel.validationMessage, "No models were returned by /v1/models.")
        XCTAssertEqual(harness.settings.activeBaseURL, "")
        XCTAssertEqual(harness.settings.validationState, .notValidated)
    }

    func testValidateAndSaveFailsForInvalidBaseURL() async throws {
        let harness = try makeHarness()

        harness.viewModel.baseURL = "http://"
        let didValidate = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )

        XCTAssertFalse(didValidate)
        XCTAssertEqual(harness.viewModel.validationState, .invalid)
        XCTAssertEqual(harness.viewModel.validationMessage, "Enter a valid server URL.")
    }

    func testValidateAndSaveUpdatesStateAcrossFailureThenRetry() async throws {
        let harness = try makeHarness()
        var shouldSucceed = false

        MockURLProtocol.setRequestHandler { _ in
            if shouldSucceed {
                return .data(body: try self.makeModelsResponse([
                    ["id": "recovered-model", "owned_by": "local"]
                ]))
            }
            return .data(statusCode: 503, body: Data("offline".utf8))
        }

        harness.viewModel.baseURL = "http://server.test:8080"

        let firstAttempt = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(harness.viewModel.validationState, .invalid)
        XCTAssertEqual(harness.viewModel.validationMessage, "Server error 503: offline")

        shouldSucceed = true

        let secondAttempt = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )
        XCTAssertTrue(secondAttempt)
        XCTAssertEqual(harness.viewModel.validationState, .valid)
        XCTAssertEqual(harness.viewModel.validationMessage, "Connected. 1 model available.")
        XCTAssertEqual(harness.settings.defaultModelID, "recovered-model")
        XCTAssertEqual(harness.settings.validationState, .valid)
    }

    func testValidateAndSaveReturnsFailureWhenKeychainSaveFails() async throws {
        let harness = try makeHarness()
        harness.keychain.saveError = MemoryKeychainStoreError.forcedSaveFailure

        MockURLProtocol.setRequestHandler { _ in
            .data(body: try self.makeModelsResponse([
                ["id": "llama-3", "owned_by": "local"]
            ]))
        }

        harness.viewModel.baseURL = "http://server.test:8080"
        harness.viewModel.apiKey = "secret"

        let didValidate = await harness.viewModel.validateAndSave(
            into: harness.settings,
            modelContext: harness.context
        )

        XCTAssertFalse(didValidate)
        XCTAssertEqual(harness.viewModel.validationState, .invalid)
        XCTAssertEqual(harness.viewModel.validationMessage, "Memory keychain save failed.")
        XCTAssertEqual(harness.settings.activeBaseURL, "")
        XCTAssertEqual(harness.settings.validationState, .notValidated)
    }

    private func makeHarness() throws -> Harness {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)
        try context.save()

        let keychain = MemoryKeychainStore()
        let client = OpenAICompatibleClient(session: TestSessionFactory.makeSession())
        let viewModel = SettingsViewModel(
            settings: settings,
            client: client,
            keychain: keychain
        )

        return Harness(
            container: container,
            context: context,
            settings: settings,
            keychain: keychain,
            viewModel: viewModel
        )
    }

    private func makeModelsResponse(_ models: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": models])
    }

    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let settings: AppSettings
        let keychain: MemoryKeychainStore
        let viewModel: SettingsViewModel
    }
}
