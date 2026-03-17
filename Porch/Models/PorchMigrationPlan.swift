import SwiftData

enum PorchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PorchSchemaV1.self,
            PorchSchemaV2.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            migrateV1ToV2
        ]
    }

    static let migrateV1ToV2 = MigrationStage.lightweight(
        fromVersion: PorchSchemaV1.self,
        toVersion: PorchSchemaV2.self
    )
}
