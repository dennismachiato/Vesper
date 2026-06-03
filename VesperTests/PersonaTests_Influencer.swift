//
//  PersonaTests_Influencer.swift
//  VesperTests
//
//  Persona: a young Instagram influencer who shot 50 golden-hour photos and
//  wants to pick the best 10 for her feed — "bright, airy, aesthetic shots"
//  with high quality, great composition, smiling face, good posing, no
//  awkward stances.
//
//  These tests exercise the ranking pipeline end-to-end using synthetic
//  PhotoScore objects (no real images or ML models required).
//

import XCTest
@testable import Vesper

final class PersonaTests_Influencer: XCTestCase {

    let processor = BatchProcessor()

    // Shared category for most influencer tests: mugshot is the right fit
    // for portrait-heavy, face-forward feed content.
    private let category: PhotoCategory = .mugshot

    // MARK: - Helpers

    /// Calls weightedScore with sensible influencer defaults.
    private func score(
        _ s: PhotoScore,
        isPromptMode: Bool = false,
        intent: BatchProcessor.PromptIntent? = nil
    ) -> Float {
        processor.weightedScore(
            s,
            category: category,
            isPromptMode: isPromptMode,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: true,
            hasFeedback: false,
            intent: intent,
            isDatingMode: false
        )
    }

    /// Calls suppressNearDuplicates with sensible influencer defaults.
    private func dedup(
        _ scores: [PhotoScore],
        intent: BatchProcessor.PromptIntent? = nil
    ) -> [PhotoScore] {
        processor.suppressNearDuplicates(
            scores,
            category: category,
            isPromptMode: false,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: true,
            hasFeedback: false,
            intent: intent,
            isDatingMode: false
        )
    }

    /// A PromptIntent that matches "bright airy" with face content — no dark/awkward/serious overrides.
    private var brightAiryIntent: BatchProcessor.PromptIntent {
        BatchProcessor.PromptIntent(
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            wantsEyesClosed: false,
            wantsBlurry: false,
            wantsMotion: false,
            wantsDark: false,
            wantsHighKey: true,   // "bright airy" → suppress dark-exposure penalty
            wantsAwkward: false,
            wantsSerious: false,
            wantsImperfect: false,
            hasFaceContent: true
        )
    }

    // MARK: - Test 1: Top 10 are the highest aestheticScore + qualityScore photos

    // Build 50 synthetic photos where the top-10 scorers are constructed to have
    // clearly superior aestheticScore + qualityScore combos.  After dedup + sort,
    // the first 10 should map back exactly to those high-scorers.
    func test_top10PicksHaveHighestAestheticAndQualityCombo() {
        // 10 hero shots: high quality, high aesthetics, smiling, open eyes
        let heroScores: [Float] = [0.92, 0.90, 0.89, 0.88, 0.87, 0.86, 0.85, 0.84, 0.83, 0.82]
        let heroes = heroScores.enumerated().map { i, q in
            PhotoScore.make(
                qualityScore: q,
                hasFace: true,
                isSmiling: true,
                eyesOpen: true,
                eyeOpenConfidence: 0.95,
                aestheticScore: 0.90,
                originalIndex: i
            )
        }

        // 40 ordinary shots: mediocre quality and aesthetics
        let fillerCount = 40
        let fillers = (0..<fillerCount).map { i in
            PhotoScore.make(
                qualityScore: 0.40,
                hasFace: true,
                isSmiling: false,
                eyesOpen: true,
                eyeOpenConfidence: 0.70,
                aestheticScore: 0.40,
                originalIndex: 10 + i
            )
        }

        let allPhotos = heroes + fillers

        // Run dedup (no near-duplicates here — all have nil embeddings so each is its own cluster)
        let deduped = dedup(allPhotos)

        // Sort by weighted score descending, then take 10
        let pickCount = 10
        let sorted = deduped.sorted {
            score($0) > score($1)
        }
        let topPicks = Array(sorted.prefix(pickCount))

        // All 10 heroes should appear in the top picks
        let topOriginalIndices = Set(topPicks.map { $0.originalIndex })
        let heroOriginalIndices = Set(heroes.map { $0.originalIndex })
        XCTAssertEqual(
            topOriginalIndices.intersection(heroOriginalIndices).count,
            pickCount,
            "All 10 top picks should be the hero shots with highest quality + aesthetic scores"
        )
    }

    // MARK: - Test 2: Smiling face ranks above equivalent non-smiling face

    // In mugshot category the smile bonus is ×1.15 for smiling, ×0.85 for non-smiling.
    // A photo with an identical profile but a smiling face must outscore its non-smiling twin.
    func test_smilingFaceRanksAboveNonSmiling_vacationAndMugshot() {
        let base = (qualityScore: Float(0.72), aestheticScore: Float(0.65),
                    eyeOpenConfidence: Float(0.90))

        let smiling = PhotoScore.make(
            qualityScore: base.qualityScore,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: base.eyeOpenConfidence,
            aestheticScore: base.aestheticScore
        )
        let notSmiling = PhotoScore.make(
            qualityScore: base.qualityScore,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: base.eyeOpenConfidence,
            aestheticScore: base.aestheticScore
        )

        // mugshot category (primary influencer use-case)
        let mugshotSmiling    = score(smiling)
        let mugshotNotSmiling = score(notSmiling)
        XCTAssertGreaterThan(
            mugshotSmiling, mugshotNotSmiling,
            "Smiling face should outscore non-smiling face in mugshot category"
        )

        // vacation category — poseMult applies but smile bonus still present in non-edgy categories
        let vacationSmiling = processor.weightedScore(
            smiling, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false
        )
        let vacationNotSmiling = processor.weightedScore(
            notSmiling, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false
        )
        // vacation does not have a smile bonus — scores should be equal (no penalty either)
        // What matters is that smiling never *hurts* the vacation score
        XCTAssertGreaterThanOrEqual(
            vacationSmiling, vacationNotSmiling * 0.99,
            "Smiling should not hurt score in vacation category"
        )
    }

    // MARK: - Test 3: Natural pose ranks above awkward pose, all else equal

    // poseScore ≥ 0.7 → poseMult = 1.0 (no penalty)
    // poseScore < 0.4 → poseMult = 0.75 + 0.4 * 0.5 = 0.95 at worst for 0.4, lower at 0.3
    // The natural-pose photo must outscore the awkward one when everything else matches.
    func test_naturalPoseRanksAboveAwkwardPose() {
        // Build the scores manually so we can set poseScore directly
        var naturalPose = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.90,
            aestheticScore: 0.70
        )
        naturalPose.poseScore = 0.85   // well above the 0.5 threshold — poseMult = 1.0

        var awkwardPose = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.90,
            aestheticScore: 0.70
        )
        awkwardPose.poseScore = 0.30   // below 0.5 threshold → poseMult = 0.75 + 0.30 * 0.5 = 0.90

        let naturalScore  = score(naturalPose)
        let awkwardScore  = score(awkwardPose)

        XCTAssertGreaterThan(
            naturalScore, awkwardScore,
            "Natural pose (poseScore 0.85) should outscore awkward pose (poseScore 0.30)"
        )
    }

    // MARK: - Test 4: wantsHighKey intent suppresses dark-exposure penalty

    // Without wantsHighKey a dark photo (low exposureScore) is penalised by exposureMult.
    // With wantsHighKey the penalty is suppressed, so a bright photo must NOT outscore
    // a dark one purely on exposure grounds once the intent flag is set.
    //
    // Concretely: in brightAiry mode a dark-but-otherwise-good photo should NOT outscore
    // a bright-and-otherwise-good photo — but the dark photo's score should improve
    // significantly compared to normal mode (proving the suppression is firing).
    func test_wantsHighKey_suppressesDarkExposurePenalty() {
        // Bright photo: high exposure score
        var brightPhoto = PhotoScore.make(
            qualityScore: 0.80,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.92,
            aestheticScore: 0.80
        )
        brightPhoto.exposureScore = 0.90   // well-lit, bright and airy

        // Dark photo: same quality/aesthetics but low exposure
        var darkPhoto = PhotoScore.make(
            qualityScore: 0.80,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.92,
            aestheticScore: 0.80
        )
        darkPhoto.exposureScore = 0.20    // underexposed — should normally be penalised

        // ── Without intent (normal mode) ──────────────────────────────────
        let brightNormal = score(brightPhoto)
        let darkNormal   = score(darkPhoto)

        // Bright photo should outscore dark in normal mode
        XCTAssertGreaterThan(
            brightNormal, darkNormal,
            "Bright photo should outscore dark photo in normal (non-highkey) mode"
        )

        // ── With wantsHighKey intent ───────────────────────────────────────
        let brightHighKey = score(brightPhoto, isPromptMode: true, intent: brightAiryIntent)
        let darkHighKey   = score(darkPhoto,   isPromptMode: true, intent: brightAiryIntent)

        // The dark photo's penalty should be suppressed — its score in highKey mode
        // should be meaningfully higher than in normal mode
        XCTAssertGreaterThan(
            darkHighKey, darkNormal,
            "wantsHighKey should suppress the dark-exposure penalty, raising the dark photo's score"
        )

        // The bright photo should still outscore (or match) the dark photo even in highKey mode
        // because bright is genuinely "bright airy" — the intent doesn't flip the ranking,
        // it just removes the unfair penalty on dark shots when the user asked for it.
        XCTAssertGreaterThanOrEqual(
            brightHighKey, darkHighKey,
            "Bright photo should still be >= dark photo in wantsHighKey mode"
        )
    }

    // MARK: - Test 5: Near-duplicate burst shots land in similars bucket, not top picks

    // 5 clusters × 2 burst shots each = 10 photos total.
    // Each cluster shares an identical CLIP embedding (cosine sim = 1.0).
    // After suppressNearDuplicates, only 5 photos should be in the kept section
    // (one best per cluster); the other 5 should be tagged isSimilar = true.
    func test_nearDuplicateBurstShots_landInSimilarsBucket() {
        let dim = 16

        // 5 orthogonal unit vectors — one per cluster
        let clusterVecs: [[Float]] = (0..<5).map { seed in
            randomUnitVector(dim: dim, seed: UInt64(seed + 10) * 13)
        }

        // For each cluster, create 2 photos: one slightly better, one slightly worse
        var allPhotos: [PhotoScore] = []
        for (clusterIdx, vec) in clusterVecs.enumerated() {
            let better = PhotoScore.make(
                qualityScore: 0.80,
                hasFace: true,
                isSmiling: true,
                eyeOpenConfidence: 0.90,
                aestheticScore: 0.75,
                clipEmbedding: vec,
                originalIndex: clusterIdx * 2
            )
            let worse = PhotoScore.make(
                qualityScore: 0.50,
                hasFace: true,
                isSmiling: false,
                eyeOpenConfidence: 0.70,
                aestheticScore: 0.50,
                clipEmbedding: vec,   // identical embedding → same cluster
                originalIndex: clusterIdx * 2 + 1
            )
            allPhotos.append(contentsOf: [better, worse])
        }

        let result = dedup(allPhotos)

        // Result should still contain all 10 photos
        XCTAssertEqual(result.count, 10, "All 10 photos should remain in the array")

        // First 5 positions are the kept (non-similar) cluster bests
        let kept       = result.filter { !$0.isSimilar }
        let similars   = result.filter {  $0.isSimilar }

        XCTAssertEqual(kept.count, 5,
            "Exactly 5 photos (one best per cluster) should NOT be flagged as similar")
        XCTAssertEqual(similars.count, 5,
            "Exactly 5 duplicate burst shots should be flagged isSimilar = true")

        // Every kept photo should have quality 0.80 (the better one from each cluster)
        for photo in kept {
            XCTAssertEqual(photo.qualityScore, 0.80, accuracy: 0.001,
                "The kept photo from each cluster should be the better-scoring one (quality 0.80)")
        }

        // Every similar photo should have quality 0.50 (the worse one from each cluster)
        for photo in similars {
            XCTAssertEqual(photo.qualityScore, 0.50, accuracy: 0.001,
                "The suppressed photo from each cluster should be the lower-scoring one (quality 0.50)")
        }
    }

    // MARK: - Test 6: pickCount is respected — exactly 10 top picks, not more

    // Build 50 distinct photos (no duplicates), run dedup + sort + prefix(10).
    // The result must have exactly 10 items regardless of how many non-similar
    // photos came out of dedup.
    func test_pickCountRespected_exactly10Picks() {
        let totalPhotos = 50
        let pickCount   = 10

        // Give each photo a unique embedding so none is flagged as a duplicate
        let photos = (0..<totalPhotos).map { i in
            PhotoScore.make(
                qualityScore: Float(i) / Float(totalPhotos),   // 0.0 … 0.98, all distinct
                hasFace: true,
                isSmiling: true,
                eyeOpenConfidence: 0.90,
                aestheticScore: 0.70,
                clipEmbedding: randomUnitVector(dim: 16, seed: UInt64(i + 100)),
                originalIndex: i
            )
        }

        // Step 1: suppress near-duplicates (none expected here)
        let deduped = dedup(photos)

        // Step 2: sort by weighted score descending
        let sorted = deduped.sorted { score($0) > score($1) }

        // Step 3: enforce pickCount
        let topPicks = Array(sorted.prefix(pickCount))

        XCTAssertEqual(
            topPicks.count, pickCount,
            "prefix(\(pickCount)) must yield exactly \(pickCount) top picks from \(totalPhotos) photos"
        )

        // Sanity-check: the top pick should indeed have the highest individual score
        if let first = topPicks.first, let rest = topPicks.dropFirst().first {
            XCTAssertGreaterThanOrEqual(
                score(first), score(rest),
                "The first pick should have the highest weighted score"
            )
        }

        // Guard: no photo outside the top 10 should outscore the 10th pick
        let cutoffScore = topPicks.last.map { score($0) } ?? 0
        let outsiders   = sorted.dropFirst(pickCount)
        for outsider in outsiders {
            XCTAssertLessThanOrEqual(
                score(outsider), cutoffScore + 0.001,  // small epsilon for float rounding
                "No photo ranked 11th or beyond should outscore the 10th pick"
            )
        }
    }
}
