import SwiftData

enum PorchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PorchSchemaV1.self,
            PorchSchemaV2.self,
            PorchSchemaV3.self,
            PorchSchemaV4.self,
            PorchSchemaV5.self,
            PorchSchemaV6.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            migrateV1ToV2,
            migrateV2ToV3,
            migrateV3ToV4,
            migrateV4ToV5,
            migrateV5ToV6
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

    static let migrateV4ToV5 = MigrationStage.custom(
        fromVersion: PorchSchemaV4.self,
        toVersion: PorchSchemaV5.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let settingsRecords = try context.fetch(FetchDescriptor<PorchSchemaV5.AppSettings>())
            for settings in settingsRecords {
                settings.isWebSearchConnectorEnabled = false
                settings.markUpdated()
            }

            if !settingsRecords.isEmpty {
                try context.save()
            }
        }
    )

    static let migrateV5ToV6 = MigrationStage.custom(
        fromVersion: PorchSchemaV5.self,
        toVersion: PorchSchemaV6.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let settingsRecords = try context.fetch(FetchDescriptor<PorchSchemaV6.AppSettings>())
            for settings in settingsRecords {
                settings.toolCallingModeRaw = ToolCallingMode.auto.rawValue
                settings.markUpdated()
            }

            if !settingsRecords.isEmpty {
                try context.save()
            }
        }
    )
}
