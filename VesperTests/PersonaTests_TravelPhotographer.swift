//
//  PersonaTests_TravelPhotographer.swift
//  VesperTests
//
//  Persona: a travel photographer culling 30 golden-hour landscape shots.
//  No faces appear in any of the photos. Category: .nature, aesthetic: .brightAiry.
//  These tests exercise the scoring pipeline when face bonuses/penalties are irrelevant,
//  verifying that quality, aesthetic, category scores — and prompt intent — drive ranking.
//

import XCTest
@testable import Vesper

final class PersonaTests_TravelPhotographer: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - Helpers

    /// Calls weightedScore with sensible landscape defaults (no face content, no prompt mode).
    private func landscapeScore(
        _ s: PhotoScore,
        isPromptMode: Bool = false,
        intent: BatchProcessor.PromptIntent? = nil
    ) -> Float {
        processor.weightedScore(
            s,
            category: .nature,
            isPromptMode: isPromptMode,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: false,
            hasFeedback: false,
            intent: intent
        )
    }

    /// Builds a PromptIntent with all flags false except those explicitly set.
    private func intent(
        wantsDark: Bool = false,
        wantsHighKey: Bool = false,
        hasFaceContent: Bool = false
    ) -> BatchProcessor.PromptIntent {
        BatchProcessor.PromptIntent(
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            wantsEyesClosed: false,
            wantsBlurry: false,
            wantsMotion: false,
            wantsDark: wantsDark,
            wantsHighKey: wantsHighKey,
            wantsAwkward: false,
            wantsSerious: false,
            wantsImperfect: false,
            hasFaceContent: hasFaceContent
        )
    }

    // MARK: - Test 1: Nature category penalises photos with faces

    // Nature is a landscape-first category. A photo with a face should score lower than
    // the same photo without a face, because the scoring formula applies a 0.2 multiplier
    // when hasFace=true.
    func test_nature_photoWithFaceScoresLowerThanPhotoWithoutFace() {
        let noFace   = PhotoScore.make(qualityScore: 0.75, hasFace: false, categoryScore: 0.8, aestheticScore: 0.7)
        let withFace = PhotoScore.make(qualityScore: 0.75, hasFace: true,  categoryScore: 0.8, aestheticScore: 0.7)

        let noFaceScore   = landscapeScore(noFace)
        let withFaceScore = landscapeScore(withFace)

        XCTAssertGreaterThan(noFaceScore, withFaceScore,
            "Nature category must penalise face presence — landscape-only shot should rank higher")
    }

    // MARK: - Test 2: Without faces, higher aestheticScore drives ranking

    // When all landscape photos have no faces, the tiebreakers are quality + category + aesthetic.
    // Two photos with identical quality and categoryScore but different aestheticScore —
    // the higher-aesthetic shot must win.
    func test_nature_higherAestheticScoreWinsWhenNoFaces() {
        let vivid  = PhotoScore.make(qualityScore: 0.70, hasFace: false, categoryScore: 0.60, aestheticScore: 0.90)
        let flat   = PhotoScore.make(qualityScore: 0.70, hasFace: false, categoryScore: 0.60, aestheticScore: 0.40)

        XCTAssertGreaterThan(landscapeScore(vivid), landscapeScore(flat),
            "Higher aestheticScore should produce a higher score when quality and category are equal")
    }

    // MARK: - Test 3: No-face photo does NOT get the solo-face penalty in nature

    // The solo-face "no face present" penalty only applies to categories where faces are expected
    // (e.g., dating mode). In nature, hasFace=false photos must not be penalised — their
    // score should be at least as high as a photo with an identical profile but with a face.
    func test_nature_noFacePhotoIsNotPenalisedByMissingFace() {
        // Both photos are otherwise identical. The no-face version should score >= the face version.
        let noFace  = PhotoScore.make(qualityScore: 0.65, hasFace: false, categoryScore: 0.70, aestheticScore: 0.65)
        let hasFace = PhotoScore.make(qualityScore: 0.65, hasFace: true,  categoryScore: 0.70, aestheticScore: 0.65)

        let noFaceScore  = landscapeScore(noFace)
        let hasFaceScore = landscapeScore(hasFace)

        // The no-face shot must not be penalised relative to the face shot.
        XCTAssertGreaterThanOrEqual(noFaceScore, hasFaceScore,
            "In nature category a hasFace=false photo should not be penalised; it should score >= hasFace=true")
    }

    // MARK: - Test 4: Prompt mode — higher promptScore wins when isPromptMode=true

    // Simulates a "golden hour warm tones" prompt. In prompt mode, promptScore dominates.
    // Two otherwise identical landscape shots: the one with a stronger prompt match should rank first.
    func test_promptMode_higherPromptScoreWinsForGoldenHour() {
        let strongMatch = PhotoScore.make(
            qualityScore: 0.65,
            hasFace: false,
            categoryScore: 0.60,
            aestheticScore: 0.60,
            promptScore: 0.80
        )
        let weakMatch = PhotoScore.make(
            qualityScore: 0.65,
            hasFace: false,
            categoryScore: 0.60,
            aestheticScore: 0.60,
            promptScore: 0.35
        )

        let strongScore = processor.weightedScore(
            strongMatch,
            category: .nature,
            isPromptMode: true,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: false,
            hasFeedback: false
        )
        let weakScore = processor.weightedScore(
            weakMatch,
            category: .nature,
            isPromptMode: true,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: false,
            hasFeedback: false
        )

        XCTAssertGreaterThan(strongScore, weakScore,
            "In prompt mode, the photo with a higher promptScore must rank above the weaker match")
    }

    // MARK: - Test 5: wantsDark intent suppresses dark-exposure penalty

    // A "moody dark landscape" prompt sets wantsDark=true. Normally an underexposed photo
    // (exposureScore 0.15) is penalised heavily vs a well-exposed photo (exposureScore 0.85).
    // With wantsDark intent the penalty is suppressed and the two scores should be within 5%
    // of each other, reflecting near-equal standing when darkness is intentional.
    func test_wantsDark_suppressesDarkExposurePenalty() {
        // Build a dark (underexposed) photo and a well-exposed photo — equal in all other respects.
        var darkPhoto  = PhotoScore.make(qualityScore: 0.70, hasFace: false, categoryScore: 0.70, aestheticScore: 0.70)
        var brightPhoto = PhotoScore.make(qualityScore: 0.70, hasFace: false, categoryScore: 0.70, aestheticScore: 0.70)
        darkPhoto.exposureScore  = 0.15   // underexposed — would normally be penalised
        brightPhoto.exposureScore = 0.85  // well exposed

        // Without wantsDark: the dark photo should score notably lower.
        let darkScoreNormal   = landscapeScore(darkPhoto)
        let brightScoreNormal = landscapeScore(brightPhoto)
        XCTAssertGreaterThan(brightScoreNormal, darkScoreNormal,
            "Without wantsDark, a well-exposed photo should score higher than an underexposed one")

        // With wantsDark intent: the penalty is suppressed — scores should be close.
        let moodyIntent = intent(wantsDark: true)
        let darkScoreIntent   = landscapeScore(darkPhoto,   intent: moodyIntent)
        let brightScoreIntent = landscapeScore(brightPhoto, intent: moodyIntent)

        let ratio = darkScoreIntent / brightScoreIntent
        XCTAssertGreaterThan(ratio, 0.95,
            "With wantsDark intent, dark photo score should be within 5% of the well-exposed photo's score")
    }

    // MARK: - Test 6: Near-duplicate landscape shots — only the sharpest escapes isSimilar

    // Simulates 5 tripod shots of the same golden-hour scene: nearly identical CLIP embeddings.
    // After suppressNearDuplicates, the sharpest photo (highest qualityScore) should be at
    // index 0, and the rest should be marked isSimilar (pushed to the tail of the returned array).
    func test_nearDuplicateLandscapes_onlySharpestEscapesSuppression() {
        // All five share the same CLIP embedding — they are effectively the same scene.
        let sharedEmbedding = randomUnitVector(dim: 16, seed: 55)

        let qualityScores: [Float] = [0.55, 0.82, 0.61, 0.70, 0.48]
        var shots = qualityScores.enumerated().map { i, q in
            PhotoScore.make(
                qualityScore: q,
                hasFace: false,
                categoryScore: 0.75,
                aestheticScore: 0.70,
                clipEmbedding: sharedEmbedding,
                originalIndex: i
            )
        }
        // Give all shots a neutral exposure to keep scoring comparable.
        for i in shots.indices { shots[i].exposureScore = 0.75 }

        let result = processor.suppressNearDuplicates(
            shots,
            category: .nature,
            isPromptMode: false,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: false,
            hasFeedback: false
        )

        // All photos are still returned (runner-up fallback).
        XCTAssertEqual(result.count, 5,
            "suppressNearDuplicates must return all photos — duplicates go to tail, not discarded")

        // The first photo in the result is the sharpest shot.
        XCTAssertEqual(result[0].qualityScore, 0.82, accuracy: 0.001,
            "The sharpest landscape shot (quality 0.82) must emerge from the cluster at position 0")

        // All photos after position 0 within this single cluster are marked as similar.
        let tailPhotos = Array(result.dropFirst())
        let allTailAreSimilar = tailPhotos.allSatisfy { $0.isSimilar }
        XCTAssertTrue(allTailAreSimilar,
            "Cluster duplicates after the best shot should all be marked isSimilar")
    }
}
