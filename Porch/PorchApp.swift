// This file defines the main application entry point for Porch.

import SwiftUI
import SwiftData

@main
struct PorchApp: App {
    var sharedModelContainer: ModelContainer = {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let schema = Schema(versionedSchema: PorchSchemaV5.self)
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
                print("Porch startup preview backfill failed: \(error)")
            }
            return container
        } catch {
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
