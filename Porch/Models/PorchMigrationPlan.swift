import SwiftData

enum PorchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PorchSchemaV1.self,
            PorchSchemaV2.self,
            PorchSchemaV3.self,
            PorchSchemaV4.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            migrateV1ToV2,
            migrateV2ToV3,
            migrateV3ToV4
        ]
    }

    static let migrateV1ToV2 = MigrationStage.lightweight(
        fromVersion: PorchSchemaV1.self,
        toVersion: PorchSchemaV2.self
    )

    static let migrateV2ToV3 = MigrationStage.custom(
        fromVersion: PorchSchemaV2.self,
        toVersion: PorchSchemaV3.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let settingsRecords = try context.fetch(FetchDescriptor<PorchSchemaV3.AppSettings>())
            for settings in settingsRecords {
                settings.isGitHubConnectorEnabled = false
                settings.markUpdated()
            }

            if !settingsRecords.isEmpty {
                try context.save()
            }
        }
    )

    static let migrateV3ToV4 = MigrationStage.lightweight(
        fromVersion: PorchSchemaV3.self,
        toVersion: PorchSchemaV4.self
    )
}
