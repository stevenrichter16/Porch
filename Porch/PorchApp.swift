//
//  PorchApp.swift
//  Porch
//
//  Created by Steven Richter on 3/16/26.
//

import os
import SwiftUI
import SwiftData

@main
struct PorchApp: App {
    private static let logger = Logger(subsystem: "com.porch.app", category: "App")
    var sharedModelContainer: ModelContainer = {
        let logger = PorchApp.logger
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let schema = Schema(versionedSchema: PorchSchemaV6.self)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isRunningTests)

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: PorchMigrationPlan.self,
                configurations: [modelConfiguration]
            )
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<AppSettings>()
            descriptor.fetchLimit = 1
            if try context.fetch(descriptor).isEmpty {
                context.insert(AppSettings())
                try context.save()
            }
            do {
                try ChatThreadMetadataBackfill.populateMissingLastMessagePreviews(in: context)
            } catch {
                logger.error("[startup] previewBackfillFailed error=\(error.localizedDescription, privacy: .public)")
            }
            logger.info("[launch] schemaVersion=V6")
            return container
        } catch {
            logger.fault("[startup] modelContainerInitFailed error=\(error.localizedDescription, privacy: .public)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
