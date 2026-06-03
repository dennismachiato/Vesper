//
//  VesperSchema.swift
//  Vesper
//
//  SwiftData migration plan. Add a new schema version here whenever a @Model
//  gains or loses stored properties. The lightweight migration handles adding
//  properties that have default values (which all new ReferencePhoto fields do).
//

import SwiftData

enum VesperSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV2: VersionedSchema {
    // V2 adds contrast, sharpness, avgFaceYaw to ReferencePhoto (all have defaults).
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV3: VersionedSchema {
    // V3 adds customName: String = "" to BatchHistory.
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV4: VersionedSchema {
    // V4 adds isNeutral: Bool = false to PhotoFeedback.
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV5: VersionedSchema {
    // V5 adds purposeTag, photoQualityScore, photoExposureScore, photoCompositionScore,
    // photoGenuineSmileScore, contrastEmbeddingData to PhotoFeedback (all have defaults).
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV7: VersionedSchema {
    // V7 adds faceCropEmbeddingData: Data? to ReferencePhoto for user face identity matching.
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV6: VersionedSchema {
    // V6 adds assetIdentifiersData: Data? and purposeTag: String = "" to BatchHistory
    // for the batch rerun feature (fetch original photos + filter feedback by purpose).
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV8: VersionedSchema {
    // V8 adds allFaceCropEmbeddingsData: Data? to ReferencePhoto — CLIP embeddings of every
    // detected face crop, so the user can be identified as the face recurring across references.
    static var versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperSchemaV9: VersionedSchema {
    // V9 adds photoFaceYaw, photoEyeOpenConfidence, photoColorHarmonyScore, photoReferenceScore,
    // userFaceIdentified to PhotoFeedback (all have defaults) — user-identity-aware angle/expression learning.
    static var versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ReferencePhoto.self, PhotoFeedback.self, BatchHistory.self]
    }
}

enum VesperMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VesperSchemaV1.self, VesperSchemaV2.self, VesperSchemaV3.self, VesperSchemaV4.self, VesperSchemaV5.self, VesperSchemaV6.self, VesperSchemaV7.self, VesperSchemaV8.self, VesperSchemaV9.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(fromVersion: VesperSchemaV1.self, toVersion: VesperSchemaV2.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV2.self, toVersion: VesperSchemaV3.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV3.self, toVersion: VesperSchemaV4.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV4.self, toVersion: VesperSchemaV5.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV5.self, toVersion: VesperSchemaV6.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV6.self, toVersion: VesperSchemaV7.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV7.self, toVersion: VesperSchemaV8.self),
            MigrationStage.lightweight(fromVersion: VesperSchemaV8.self, toVersion: VesperSchemaV9.self),
        ]
    }
}
