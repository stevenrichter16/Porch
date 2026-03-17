import SwiftData
import XCTest
@testable import Porch

@MainActor
final class PersistenceTests: XCTestCase {
    func testMigrationFromV1StoreLoadsExistingChats() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("Porch.store")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        do {
            let schema = Schema(versionedSchema: PorchSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            context.insert(PorchSchemaV1.AppSettings())
            let thread = PorchSchemaV1.ChatThread(
                serverBaseURL: "http://server.test",
                modelID: "model",
                systemPrompt: ""
            )
            context.insert(thread)
            context.insert(
                PorchSchemaV1.ChatMessage(
                    role: .user,
                    content: "First",
                    thread: thread,
                    createdAt: Date(timeIntervalSince1970: 10)
                )
            )
            context.insert(
                PorchSchemaV1.ChatMessage(
                    role: .assistant,
                    content: "Latest reply",
                    thread: thread,
                    createdAt: Date(timeIntervalSince1970: 20)
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: PorchSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PorchMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        let migratedThread = try XCTUnwrap(threads.first)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(migratedThread.title, "New Chat")
        XCTAssertEqual(migratedThread.serverBaseURL, "http://server.test")
        XCTAssertEqual(migratedThread.lastMessagePreview, "")

        let migratedMessages = try ChatMessageQueries.fetchSortedMessages(for: migratedThread, in: context)
        XCTAssertEqual(migratedMessages.map(\.content), ["First", "Latest reply"])

        let updatedCount = try ChatThreadMetadataBackfill.populateMissingLastMessagePreviews(in: context)
        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(migratedThread.lastMessagePreview, "Latest reply")
    }

    func testNewThreadStartsWithEmptyLastMessagePreview() {
        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        XCTAssertEqual(thread.lastMessagePreview, "")
    }

    func testChatThreadRetainsSettingsSnapshotValues() throws {
        let settings = AppSettings()
        settings.activeBaseURL = "http://macbook.local:1234/v1"
        settings.defaultModelID = "qwen"
        settings.defaultSystemPrompt = "Original prompt"

        let thread = ChatThread(
            serverBaseURL: settings.activeBaseURL,
            modelID: settings.defaultModelID,
            systemPrompt: settings.defaultSystemPrompt
        )

        settings.activeBaseURL = "http://other-host:1234/v1"
        settings.defaultModelID = "llama"
        settings.defaultSystemPrompt = "Updated prompt"

        XCTAssertEqual(thread.serverBaseURL, "http://macbook.local:1234/v1")
        XCTAssertEqual(thread.modelID, "qwen")
        XCTAssertEqual(thread.systemPrompt, "Original prompt")
    }

    func testChatThreadApplyMessageMutationUpdatesPreview() {
        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        let userMessage = ChatMessage(role: .user, content: "Line one\nLine two", thread: thread)

        thread.applyMessageMutation(latestMessage: userMessage)

        XCTAssertEqual(thread.lastMessagePreview, "Line one Line two")
    }

    func testChatMessagesAreSortedByCreationDate() {
        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        let later = ChatMessage(
            role: .assistant,
            content: "Later",
            thread: thread,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let earlier = ChatMessage(
            role: .user,
            content: "Earlier",
            thread: thread,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        thread.messages = [later, earlier]

        XCTAssertEqual(thread.sortedMessages.map(\.content), ["Earlier", "Later"])
    }

    func testChatMessageQueriesFetchSortedMessagesForThread() throws {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)

        let firstThread = ChatThread(serverBaseURL: "http://server.test", modelID: "alpha", systemPrompt: "")
        let secondThread = ChatThread(serverBaseURL: "http://server.test", modelID: "beta", systemPrompt: "")
        context.insert(firstThread)
        context.insert(secondThread)
        context.insert(ChatMessage(role: .assistant, content: "Later", thread: firstThread, createdAt: Date(timeIntervalSince1970: 20)))
        context.insert(ChatMessage(role: .user, content: "Earlier", thread: firstThread, createdAt: Date(timeIntervalSince1970: 10)))
        context.insert(ChatMessage(role: .assistant, content: "Other thread", thread: secondThread, createdAt: Date(timeIntervalSince1970: 15)))
        try context.save()

        let messages = try ChatMessageQueries.fetchSortedMessages(for: firstThread, in: context)

        XCTAssertEqual(messages.map(\.content), ["Earlier", "Later"])
    }

    func testBackfillPopulatesMissingLastMessagePreviewWithoutChangingMessages() throws {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)

        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        context.insert(thread)
        context.insert(ChatMessage(role: .user, content: "First", thread: thread, createdAt: Date(timeIntervalSince1970: 10)))
        context.insert(ChatMessage(role: .assistant, content: "Latest reply", thread: thread, createdAt: Date(timeIntervalSince1970: 20)))
        try context.save()

        let updatedCount = try ChatThreadMetadataBackfill.populateMissingLastMessagePreviews(in: context)
        let refreshedMessages = try ChatMessageQueries.fetchSortedMessages(for: thread, in: context)

        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(thread.lastMessagePreview, "Latest reply")
        XCTAssertEqual(refreshedMessages.map(\.content), ["First", "Latest reply"])
    }

    func testDeletingThreadCascadesMessages() throws {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)

        let thread = ChatThread(serverBaseURL: "http://server.test", modelID: "model", systemPrompt: "")
        context.insert(thread)
        context.insert(ChatMessage(role: .user, content: "Hi", thread: thread))
        context.insert(ChatMessage(role: .assistant, content: "Hello", thread: thread))
        try context.save()

        context.delete(thread)
        try context.save()

        let descriptor = FetchDescriptor<ChatMessage>()
        let messages = try context.fetch(descriptor)
        XCTAssertTrue(messages.isEmpty)
    }

    func testAppSettingsRoundTripGenerationParametersAndAvailableModels() {
        let settings = AppSettings()
        let parameters = GenerationParameters(
            temperature: 1.1,
            maxTokens: 4096,
            topP: 0.8,
            frequencyPenalty: 0.4,
            presencePenalty: -0.2,
            stopSequences: ["```", "</END>"]
        )
        let models = [
            RemoteModel(id: "alpha", ownedBy: "local"),
            RemoteModel(id: "beta", ownedBy: "local")
        ]

        settings.generationParameters = parameters
        settings.availableModels = models

        XCTAssertEqual(settings.generationParameters, parameters)
        XCTAssertEqual(settings.availableModels, models)
    }
}
