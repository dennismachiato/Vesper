//
//  PhotoFeedback.swift
//  Vesper
//

import SwiftData
import UIKit

@Model
class PhotoFeedback {
    var liked: Bool
    var isNeutral: Bool = false  // true when user tapped "Meh" — neither liked nor disliked
    var reason: String          // filled when disliked; empty when liked/neutral
    var embeddingData: Data     // CLIP image embedding of the photo
    var reasonEmbeddingData: Data  // CLIP text embedding of the reason (empty if no reason)
    var createdAt: Date

    // V5 additions — all have defaults so lightweight migration works
    /// The BatchPurpose rawValue when feedback was given (e.g. "Dating profile"). Empty = unknown.
    var purposeTag: String = ""
    /// Technical dimension scores of the photo at feedback time — used for per-user weight learning (feature 6).
    var photoQualityScore: Float = 0.5
    var photoExposureScore: Float = 0.5
    var photoCompositionScore: Float = 0.5
    var photoGenuineSmileScore: Float = 0.5
    /// CLIP embedding of the photo seen immediately before this one — contrastive feedback (feature 7).
    var contrastEmbeddingData: Data = Data()

    // V9 additions — user-identity-aware angle/expression learning. All defaulted for lightweight migration.
    /// Yaw (head turn) of the identified user's face at feedback time, in radians. 0 = facing camera.
    var photoFaceYaw: Float = 0
    /// Eye-open confidence of the identified user's face at feedback time (0..1).
    var photoEyeOpenConfidence: Float = 0.5
    /// Color-harmony score of the photo at feedback time (0..1).
    var photoColorHarmonyScore: Float = 0.5
    /// Reference-similarity score of the photo at feedback time (0..1).
    var photoReferenceScore: Float = 0.5
    /// Whether the user's own face was identified in this photo — gates angle/expression learning.
    var userFaceIdentified: Bool = false

    init(liked: Bool, isNeutral: Bool = false, reason: String = "",
         imageEmbedding: [Float], reasonEmbedding: [Float] = [],
         purposeTag: String = "",
         qualityScore: Float = 0.5, exposureScore: Float = 0.5,
         compositionScore: Float = 0.5, genuineSmileScore: Float = 0.5,
         contrastEmbedding: [Float] = [],
         faceYaw: Float = 0, eyeOpenConfidence: Float = 0.5,
         colorHarmonyScore: Float = 0.5, referenceScore: Float = 0.5,
         userFaceIdentified: Bool = false) {
        self.liked = liked
        self.isNeutral = isNeutral
        self.reason = reason
        self.embeddingData = imageEmbedding.withUnsafeBytes { Data($0) }
        self.reasonEmbeddingData = reasonEmbedding.withUnsafeBytes { Data($0) }
        self.createdAt = Date()
        self.purposeTag = purposeTag
        self.photoQualityScore = qualityScore
        self.photoExposureScore = exposureScore
        self.photoCompositionScore = compositionScore
        self.photoGenuineSmileScore = genuineSmileScore
        self.contrastEmbeddingData = contrastEmbedding.withUnsafeBytes { Data($0) }
        self.photoFaceYaw = faceYaw
        self.photoEyeOpenConfidence = eyeOpenConfidence
        self.photoColorHarmonyScore = colorHarmonyScore
        self.photoReferenceScore = referenceScore
        self.userFaceIdentified = userFaceIdentified
    }

    var imageEmbedding: [Float] {
        embeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    var reasonEmbedding: [Float] {
        reasonEmbeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    var contrastEmbedding: [Float] {
        contrastEmbeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
