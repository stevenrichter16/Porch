import SwiftData
@testable import Porch

enum TestModelContainerFactory {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: PorchSchemaV7.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: PorchMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
