//
//  PersonaTests_BurstMom.swift
//  VesperTests
//
//  Persona: A mom who spam-clicked the shutter taking 50 near-identical photos of
//  one pose. She wants the single best shot surfaced and all the duplicates cleared.
//
//  Covers:
//   • Near-duplicate suppression across a 50-photo burst (same CLIP embedding)
//   • Representative selection: highest weightedScore wins from a cluster of 10
//   • isSimilar flag — representative must NOT be marked similar
//   • isDeleteCandidate logic: quality floor, closed-eyes, and borderline cases
//

import XCTest
@testable import Vesper

final class PersonaTests_BurstMom: XCTestCase {

    let processor = BatchProcessor()

    // Convenience: a neutral PromptIntent with hasFaceContent = true so that
    // the closed-eyes and quality-floor deletion rules are active.
    private var neutralIntent: BatchProcessor.PromptIntent {
        BatchProcessor.PromptIntent(
            wantsLookingAway:    false,
            wantsLookingAtCamera: false,
            wantsEyesClosed:     false,
            wantsBlurry:         false,
            wantsMotion:         false,
            wantsDark:           false,
            wantsHighKey:        false,
            wantsAwkward:        false,
            wantsSerious:        false,
            wantsImperfect:      false,
            hasFaceContent:      true
        )
    }

    // MARK: - 1. Near-duplicate suppression: 49 of 50 should be marked isSimilar

    // Mom hammered the shutter 50 times. Every frame shares the same scene embedding
    // so they all land in one cluster. Only the best-scoring photo should escape.
    func test_burst50_49MarkedAsSimilar() {
        let sharedEmb = randomUnitVector(dim: 512, seed: 1)

        // Spread quality across the burst so there is a clear winner (index 0, quality 0.90).
        var scores: [PhotoScore] = []
        for i in 0..<50 {
            let q: Float = i == 0 ? 0.90 : Float(50 - i) / 100.0   // 0.90, 0.49, 0.48 … 0.02
            scores.append(PhotoScore.make(
                qualityScore:      q,
                hasFace:           true,
                eyeOpenConfidence: 0.85,
                clipEmbedding:     sharedEmb,
                originalIndex:     i
            ))
        }

        let result = processor.suppressNearDuplicates(
            scores,
            category:             .mugshot,
            isPromptMode:         false,
            dynamicRefWeight:     0,
            wantsLookingAway:     false,
            wantsLookingAtCamera: false,
            hasFeedback:          false
        )

        let similarCount = result.filter { $0.isSimilar }.count
        XCTAssertEqual(similarCount, 49,
            "49 of the 50 near-identical burst shots must be tagged isSimilar=true")
    }

    // MARK: - 2. Representative is the highest weightedScore photo in its cluster

    // Among 10 near-identical frames, the one with the highest quality (and therefore
    // highest weightedScore) should be chosen as the cluster representative.
    func test_clusterOf10_representativeHasHighestWeightedScore() {
        let sharedEmb = randomUnitVector(dim: 512, seed: 1)

        let qualities: [Float] = [0.30, 0.55, 0.42, 0.78, 0.61, 0.25, 0.50, 0.88, 0.47, 0.33]
        let bestQuality: Float = 0.88   // index 7

        let scores = qualities.enumerated().map { i, q in
            PhotoScore.make(
                qualityScore:      q,
                hasFace:           true,
                eyeOpenConfidence: 0.80,
                clipEmbedding:     sharedEmb,
                originalIndex:     i
            )
        }

        let result = processor.suppressNearDuplicates(
            scores,
            category:             .mugshot,
            isPromptMode:         false,
            dynamicRefWeight:     0,
            wantsLookingAway:     false,
            wantsLookingAtCamera: false,
            hasFeedback:          false
        )

        // The representative is the only photo NOT marked isSimilar.
        let notSimilar = result.filter { !$0.isSimilar }
        XCTAssertEqual(notSimilar.count, 1,
            "Exactly one photo should survive as the cluster representative")
        XCTAssertEqual(notSimilar.first?.qualityScore ?? 0, bestQuality, accuracy: 0.001,
            "The representative must be the photo with the highest weightedScore (quality 0.88)")
    }

    // MARK: - 3. Representative is NOT marked isSimilar

    // The best photo from the burst should be surfaced for the mom to keep —
    // it must not be buried in the similar pile.
    func test_representative_isNotMarkedSimilar() {
        let sharedEmb = randomUnitVector(dim: 512, seed: 1)

        let scores = [
            PhotoScore.make(qualityScore: 0.40, clipEmbedding: sharedEmb, originalIndex: 0),
            PhotoScore.make(qualityScore: 0.75, clipEmbedding: sharedEmb, originalIndex: 1),
            PhotoScore.make(qualityScore: 0.55, clipEmbedding: sharedEmb, originalIndex: 2),
        ]

        let result = processor.suppressNearDuplicates(
            scores,
            category:             .mugshot,
            isPromptMode:         false,
            dynamicRefWeight:     0,
            wantsLookingAway:     false,
            wantsLookingAtCamera: false,
            hasFeedback:          false
        )

        // Find the photo with quality 0.75 — it must not be similar-tagged.
        let representative = result.first { abs($0.qualityScore - 0.75) < 0.001 }
        XCTAssertNotNil(representative, "Photo with quality 0.75 should still be in the result array")
        XCTAssertFalse(representative!.isSimilar,
            "The cluster representative (best-scoring photo) must NOT be marked isSimilar")
    }

    // MARK: - 4a. Borderline delete-candidate: eyes barely open (eyeOpenConfidence 0.19)

    // A shot where the child's eyes are almost — but not quite — open.
    // eyeOpenConfidence 0.19 is just below the 0.20 threshold, so it should be flagged.
    func test_deleteCandidates_eyesBarelyOpen_isFlagged() {
        let score = PhotoScore.make(
            qualityScore:      0.40,
            hasFace:           true,
            eyeOpenConfidence: 0.19   // just below threshold
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(score, intent: neutralIntent, refPrefersSharp: true),
            "A face photo with eyeOpenConfidence 0.19 should be a delete candidate (eyes barely open)"
        )
    }

    // MARK: - 4b. Borderline delete-candidate: eyes clearly closed (eyeOpenConfidence 0.05)

    // Classic blink shot — everyone's eyes shut right at the shutter click.
    func test_deleteCandidates_eyesClearlyClosedLowConfidence_isFlagged() {
        let score = PhotoScore.make(
            qualityScore:      0.50,
            hasFace:           true,
            eyeOpenConfidence: 0.05   // clearly closed
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(score, intent: neutralIntent, refPrefersSharp: true),
            "A face photo with eyeOpenConfidence 0.05 should be a delete candidate (eyes clearly closed)"
        )
    }

    // MARK: - 4c. Borderline delete-candidate: eyes clearly open (eyeOpenConfidence 0.95)

    // The hero shot — good expression, eyes wide open. Must NOT be flagged for deletion.
    func test_deleteCandidates_eyesClearlyOpen_isNotFlagged() {
        let score = PhotoScore.make(
            qualityScore:      0.40,
            hasFace:           true,
            eyeOpenConfidence: 0.95   // clearly open
        )
        XCTAssertFalse(
            processor.isDeleteCandidate(score, intent: neutralIntent, refPrefersSharp: true),
            "A face photo with eyeOpenConfidence 0.95 should NOT be a delete candidate (eyes clearly open)"
        )
    }

    // MARK: - 5. Very low quality (< 0.20) is always a delete candidate

    // A completely blurry, shaky frame from the burst — no face detail at all.
    // The quality floor applies regardless of face/eye state.
    func test_deleteCandidates_veryLowQuality_alwaysFlagged() {
        let noFaceBlurry = PhotoScore.make(qualityScore: 0.10, hasFace: false)
        let faceBlurry   = PhotoScore.make(qualityScore: 0.18, hasFace: true, eyeOpenConfidence: 0.90)
        let borderline   = PhotoScore.make(qualityScore: 0.19, hasFace: false)

        XCTAssertTrue(
            processor.isDeleteCandidate(noFaceBlurry, intent: neutralIntent, refPrefersSharp: true),
            "Quality 0.10 (no face) must be a delete candidate — below the 0.20 quality floor"
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(faceBlurry, intent: neutralIntent, refPrefersSharp: true),
            "Quality 0.18 (face, open eyes) must be a delete candidate — below the 0.20 quality floor"
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(borderline, intent: neutralIntent, refPrefersSharp: true),
            "Quality 0.19 must be a delete candidate — still below the 0.20 floor"
        )
    }

    // MARK: - 6. Moderate quality + closed eyes → delete candidate

    // A shot that's technically in-focus (quality 0.45) but the kid blinked.
    // The closed-eye rule should override the acceptable quality score.
    func test_deleteCandidates_moderateQualityClosedEyes_isFlagged() {
        let score = PhotoScore.make(
            qualityScore:      0.45,
            hasFace:           true,
            eyeOpenConfidence: 0.05   // clearly closed
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(score, intent: neutralIntent, refPrefersSharp: true),
            "Quality 0.45 with eyeOpenConfidence 0.05 should be a delete candidate (closed eyes override)"
        )
    }

    // MARK: - 7. Moderate quality + open eyes → NOT a delete candidate

    // The photo mom actually wants to keep: decent sharpness, everyone's eyes open.
    func test_deleteCandidates_moderateQualityOpenEyes_isNotFlagged() {
        let score = PhotoScore.make(
            qualityScore:      0.45,
            hasFace:           true,
            eyeOpenConfidence: 0.90   // clearly open
        )
        XCTAssertFalse(
            processor.isDeleteCandidate(score, intent: neutralIntent, refPrefersSharp: true),
            "Quality 0.45 with eyeOpenConfidence 0.90 should NOT be a delete candidate (open eyes, acceptable quality)"
        )
    }

    func test_cleanupFallbackDeleteCandidates_surfacesWeakReviewPhotos() {
        let strong = PhotoScore.make(
            qualityScore: 0.78,
            exposureScore: 0.72,
            compositionScore: 0.68,
            originalIndex: 1
        )
        let soft = PhotoScore.make(
            qualityScore: 0.33,
            exposureScore: 0.62,
            compositionScore: 0.60,
            originalIndex: 2
        )
        let dim = PhotoScore.make(
            qualityScore: 0.62,
            exposureScore: 0.31,
            compositionScore: 0.55,
            originalIndex: 3
        )
        let awkward = PhotoScore.make(
            qualityScore: 0.66,
            hasFace: true,
            eyeOpenConfidence: 0.82,
            eyeState: .open,
            poseScore: 0.20,
            originalIndex: 4
        )

        let fallback = processor.cleanupFallbackDeleteCandidates(
            from: [strong, soft, dim, awkward],
            maxCount: 3
        )
        let fallbackIDs = Set(fallback.map(\.originalIndex))

        XCTAssertEqual(fallback.count, 3)
        XCTAssertTrue(fallbackIDs.contains(2), "Soft cleanup shots should be offered for review.")
        XCTAssertTrue(fallbackIDs.contains(3), "Poorly lit cleanup shots should be offered for review.")
        XCTAssertTrue(fallbackIDs.contains(4), "Awkward-pose cleanup shots should be offered for review.")
        XCTAssertFalse(fallbackIDs.contains(1), "Strong photos should not be backfilled into deletion review.")
    }

    func test_cleanupFallbackDeleteCandidates_skipsStrongPhotos() {
        let candidates = (0..<12).map { index in
            PhotoScore.make(
                qualityScore: 0.72,
                exposureScore: 0.70,
                compositionScore: 0.64,
                originalIndex: index
            )
        }

        XCTAssertTrue(
            processor.cleanupFallbackDeleteCandidates(from: candidates, maxCount: 5).isEmpty,
            "Cleanup fallback should not invent delete suggestions when every candidate is strong."
        )
    }

    func test_cleanupFallbackGate_onlyRunsForLargeCleanupBatchesWithoutObjectiveDeletes() {
        XCTAssertTrue(
            processor.shouldUseCleanupFallbackDeleteCandidates(
                purposeTag: BatchPurpose.cleanup.rawValue,
                nonTopPickCount: 20,
                objectiveDeleteCount: 0
            )
        )
        XCTAssertFalse(
            processor.shouldUseCleanupFallbackDeleteCandidates(
                purposeTag: BatchPurpose.dating.rawValue,
                nonTopPickCount: 20,
                objectiveDeleteCount: 0
            )
        )
        XCTAssertFalse(
            processor.shouldUseCleanupFallbackDeleteCandidates(
                purposeTag: BatchPurpose.cleanup.rawValue,
                nonTopPickCount: 9,
                objectiveDeleteCount: 0
            )
        )
        XCTAssertFalse(
            processor.shouldUseCleanupFallbackDeleteCandidates(
                purposeTag: BatchPurpose.cleanup.rawValue,
                nonTopPickCount: 20,
                objectiveDeleteCount: 1
            )
        )
    }

    // MARK: - Distinct clusters are not cross-contaminated

    // Some burst shots from a different scene (different seed) should form their own
    // cluster and not suppress photos from the first scene.
    func test_twoClusters_representativesFromEachSurvive() {
        let emb1 = randomUnitVector(dim: 512, seed: 1)
        let emb2 = randomUnitVector(dim: 512, seed: 99)

        // 3 near-duplicates from scene A (best quality: 0.80)
        let sceneA = [
            PhotoScore.make(qualityScore: 0.80, clipEmbedding: emb1, originalIndex: 0),
            PhotoScore.make(qualityScore: 0.55, clipEmbedding: emb1, originalIndex: 1),
            PhotoScore.make(qualityScore: 0.45, clipEmbedding: emb1, originalIndex: 2),
        ]
        // 3 near-duplicates from scene B (best quality: 0.72)
        let sceneB = [
            PhotoScore.make(qualityScore: 0.72, clipEmbedding: emb2, originalIndex: 3),
            PhotoScore.make(qualityScore: 0.50, clipEmbedding: emb2, originalIndex: 4),
            PhotoScore.make(qualityScore: 0.35, clipEmbedding: emb2, originalIndex: 5),
        ]

        let result = processor.suppressNearDuplicates(
            sceneA + sceneB,
            category:             .vacation,
            isPromptMode:         false,
            dynamicRefWeight:     0,
            wantsLookingAway:     false,
            wantsLookingAtCamera: false,
            hasFeedback:          false
        )

        let survivors = result.filter { !$0.isSimilar }
        XCTAssertEqual(survivors.count, 2,
            "One representative per cluster — two survivors total")

        let survivorQualities = survivors.map { $0.qualityScore }.sorted(by: >)
        XCTAssertEqual(survivorQualities[0], 0.80, accuracy: 0.001,
            "Best from scene A (quality 0.80) should survive")
        XCTAssertEqual(survivorQualities[1], 0.72, accuracy: 0.001,
            "Best from scene B (quality 0.72) should survive")
    }
}
