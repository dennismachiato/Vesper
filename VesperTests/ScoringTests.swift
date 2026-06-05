//
//  ScoringTests.swift
//  VesperTests
//
//  Tests for BatchProcessor.weightedScore — verifies that the ranking logic
//  produces the right order for known inputs, without needing Vision or CLIP.
//

import XCTest
@testable import Vesper

final class ScoringTests: XCTestCase {

    let processor = BatchProcessor()
    private var neutralIntent: BatchProcessor.PromptIntent {
        BatchProcessor.PromptIntent(
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            wantsEyesClosed: false,
            wantsBlurry: false,
            wantsMotion: false,
            wantsDark: false,
            wantsHighKey: false,
            wantsAwkward: false,
            wantsSerious: false,
            wantsImperfect: false,
            hasFaceContent: true
        )
    }

    // MARK: - Basic quality ranking

    func test_sharpPhotoRanksAboveBlurry() {
        let sharp = PhotoScore.make(qualityScore: 0.90, categoryScore: 0.5, aestheticScore: 0.5)
        let blurry = PhotoScore.make(qualityScore: 0.20, categoryScore: 0.5, aestheticScore: 0.5)

        let sharpScore = score(sharp, category: .vacation)
        let blurryScore = score(blurry, category: .vacation)

        XCTAssertGreaterThan(sharpScore, blurryScore)
    }

    // MARK: - Eye penalty

    func test_openEyesRanksAboveClosedEyes_mugshot() {
        let open   = PhotoScore.make(qualityScore: 0.7, hasFace: true, eyesOpen: true,  eyeOpenConfidence: 0.95)
        let closed = PhotoScore.make(qualityScore: 0.7, hasFace: true, eyesOpen: false, eyeOpenConfidence: 0.05)

        XCTAssertGreaterThan(score(open, category: .mugshot), score(closed, category: .mugshot))
    }

    func test_eyePenaltyIsProportional() {
        // eyePenalty = 0.4 + confidence * 0.6
        // confidence 1.0 → penalty 1.0 (no reduction)
        // confidence 0.0 → penalty 0.4 (60% reduction)
        let fullyOpen  = PhotoScore.make(qualityScore: 0.8, hasFace: true, eyeOpenConfidence: 1.0)
        let fullyClosed = PhotoScore.make(qualityScore: 0.8, hasFace: true, eyeOpenConfidence: 0.0)
        let mid        = PhotoScore.make(qualityScore: 0.8, hasFace: true, eyeOpenConfidence: 0.5)

        let sOpen   = score(fullyOpen, category: .vacation)
        let sMid    = score(mid, category: .vacation)
        let sClosed = score(fullyClosed, category: .vacation)

        XCTAssertGreaterThan(sOpen, sMid)
        XCTAssertGreaterThan(sMid, sClosed)
        // Confirm the 60% cap: closed-eye score ≥ 40% of open-eye score
        XCTAssertGreaterThanOrEqual(sClosed, sOpen * 0.38)   // allow tiny float rounding
    }

    func test_learnedClosedEyeTolerance_firesFromLikedClosedEyeFeedback() {
        let likedClosed = makeFeedback(
            liked: true,
            quality: 0.75,
            comp: 0.72,
            smile: 0.88,
            eyes: 0.08,
            reference: 0.70,
            yaw: 0.25,
            userFaceIdentified: true
        )

        let tolerance = processor.learnedClosedEyeTolerance(from: [likedClosed])

        XCTAssertGreaterThan(tolerance, 0.10,
            "A liked closed-eye self-photo should immediately create a gentle tolerance signal")
    }

    func test_closedEyeTolerance_softensOnlyStrongClosedEyePhotos() {
        var strongClosed = PhotoScore.make(
            qualityScore: 0.78,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.08,
            faceYaw: 0.25,
            exposureScore: 0.78,
            compositionScore: 0.78,
            poseScore: 0.82,
            categoryScore: 0.68,
            aestheticScore: 0.74,
            referenceScore: 0.76
        )
        strongClosed.genuineSmileScore = 0.90
        strongClosed.colorHarmonyScore = 0.72

        var weakClosed = PhotoScore.make(
            qualityScore: 0.45,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.08,
            faceYaw: 0.82,
            exposureScore: 0.48,
            compositionScore: 0.28,
            poseScore: 0.22,
            categoryScore: 0.45,
            aestheticScore: 0.42,
            referenceScore: 0.30
        )
        weakClosed.genuineSmileScore = 0.10
        weakClosed.colorHarmonyScore = 0.35

        let strongDefault = score(strongClosed, category: .vacation)
        let strongLearned = processor.weightedScore(
            strongClosed,
            category: .vacation,
            isPromptMode: false,
            dynamicRefWeight: 0,
            closedEyeTolerance: 1.0
        )
        let weakDefault = score(weakClosed, category: .vacation)
        let weakLearned = processor.weightedScore(
            weakClosed,
            category: .vacation,
            isPromptMode: false,
            dynamicRefWeight: 0,
            closedEyeTolerance: 1.0
        )

        XCTAssertGreaterThan(strongLearned, strongDefault,
            "A strong closed-eye photo should get penalty relief when the user likes that look")
        XCTAssertLessThanOrEqual(weakLearned, weakDefault + 0.01,
            "Closed-eye tolerance should not rescue a weak photo with bad angle/expression")
    }

    func test_eyeHintStillTightensClosedEyesDespiteTolerance() {
        var strongClosed = PhotoScore.make(
            qualityScore: 0.78,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.08,
            faceYaw: 0.25,
            compositionScore: 0.78,
            poseScore: 0.82,
            categoryScore: 0.68,
            aestheticScore: 0.74,
            referenceScore: 0.76
        )
        strongClosed.genuineSmileScore = 0.90

        let tolerantScore = processor.weightedScore(
            strongClosed,
            category: .vacation,
            isPromptMode: false,
            dynamicRefWeight: 0,
            closedEyeTolerance: 1.0
        )
        let explicitEyeDislikeScore = processor.weightedScore(
            strongClosed,
            category: .vacation,
            isPromptMode: false,
            dynamicRefWeight: 0,
            dimHints: ["eyeOpenConfidence": 1.40],
            closedEyeTolerance: 1.0
        )

        XCTAssertGreaterThan(tolerantScore, explicitEyeDislikeScore,
            "An explicit closed-eye dislike should still tighten the penalty")
    }

    func test_obscuredEyesArePenalizedLessThanTrueClosedEyes() {
        let sunglasses = PhotoScore.make(
            qualityScore: 0.72,
            hasFace: true,
            eyeOpenConfidence: 0.5,
            eyeState: .unknown,
            eyeOcclusionScore: 0.85,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        let closed = PhotoScore.make(
            qualityScore: 0.72,
            hasFace: true,
            eyeOpenConfidence: 0.08,
            eyeState: .closed,
            eyeOcclusionScore: 0.05,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )

        XCTAssertGreaterThan(score(sunglasses, category: .vacation), score(closed, category: .vacation),
            "Sunglasses/obscured eyes should be treated as uncertainty, not as a confident blink")
    }

    func test_visibleEyeAsymmetryLowersScore() {
        let balanced = PhotoScore.make(
            qualityScore: 0.72,
            hasFace: true,
            eyeOpenConfidence: 0.86,
            eyeState: .open,
            eyeSymmetryScore: 0.95,
            eyeOcclusionScore: 0.05,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        let uneven = PhotoScore.make(
            qualityScore: 0.72,
            hasFace: true,
            eyeOpenConfidence: 0.86,
            eyeState: .open,
            eyeSymmetryScore: 0.25,
            eyeOcclusionScore: 0.05,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )

        XCTAssertGreaterThan(score(balanced, category: .mugshot), score(uneven, category: .mugshot),
            "When eyes are visible, strong left/right mismatch should lower the ranking")
    }

    func test_batchRelativeScoreNudgesSimilarFrameWinner() {
        let winner = PhotoScore.make(
            qualityScore: 0.65,
            hasFace: true,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.60,
            aestheticScore: 0.60,
            batchRelativeScore: 0.95
        )
        let weakerFrame = PhotoScore.make(
            qualityScore: 0.65,
            hasFace: true,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.60,
            aestheticScore: 0.60,
            batchRelativeScore: 0.25
        )

        XCTAssertGreaterThan(score(winner, category: .vacation), score(weakerFrame, category: .vacation),
            "The best frame from a similar-photo cluster should get a gentle ranking lift")
    }

    func test_closedEyeTolerance_keepsStrongClosedEyePhotoOutOfDeleteCandidates() {
        var strongClosed = PhotoScore.make(
            qualityScore: 0.70,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.05,
            faceYaw: 0.22,
            compositionScore: 0.80,
            poseScore: 0.82,
            referenceScore: 0.74
        )
        strongClosed.genuineSmileScore = 0.92

        let weakClosed = PhotoScore.make(
            qualityScore: 0.42,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.05,
            faceYaw: 0.85,
            compositionScore: 0.25,
            poseScore: 0.20,
            referenceScore: 0.20
        )

        XCTAssertFalse(
            processor.isDeleteCandidate(
                strongClosed,
                intent: neutralIntent,
                refPrefersSharp: true,
                closedEyeTolerance: 1.0
            ),
            "A strong closed-eye photo should not be auto-marked for deletion once tolerance is learned"
        )
        XCTAssertTrue(
            processor.isDeleteCandidate(
                weakClosed,
                intent: neutralIntent,
                refPrefersSharp: true,
                closedEyeTolerance: 1.0
            ),
            "Tolerance should not protect a weak closed-eye photo with bad expression and angle"
        )
    }

    // MARK: - Smile bonus / penalty

    func test_smilingBoostsMugshot() {
        let smiling    = PhotoScore.make(qualityScore: 0.7, hasFace: true, isSmiling: true,  eyeOpenConfidence: 0.9)
        let notSmiling = PhotoScore.make(qualityScore: 0.7, hasFace: true, isSmiling: false, eyeOpenConfidence: 0.9)

        XCTAssertGreaterThan(score(smiling, category: .mugshot), score(notSmiling, category: .mugshot))
    }

    func test_smilingPenalisesEdgy() {
        let smiling    = PhotoScore.make(qualityScore: 0.7, hasFace: true, isSmiling: true)
        let notSmiling = PhotoScore.make(qualityScore: 0.7, hasFace: true, isSmiling: false)

        XCTAssertLessThan(score(smiling, category: .edgy), score(notSmiling, category: .edgy))
    }

    // MARK: - Nature: face penalty

    func test_nature_noFaceRanksAboveFace() {
        let noFace  = PhotoScore.make(qualityScore: 0.7, hasFace: false, categoryScore: 0.8, aestheticScore: 0.7)
        let withFace = PhotoScore.make(qualityScore: 0.7, hasFace: true,  categoryScore: 0.8, aestheticScore: 0.7)

        XCTAssertGreaterThan(score(noFace, category: .nature), score(withFace, category: .nature))
    }

    // MARK: - Gaze multiplier

    func test_lookingAwayBoostWhenPromptWantsLookingAway() {
        let lookingAway   = PhotoScore.make(qualityScore: 0.7, hasFace: true, faceYaw: 0.4,  promptScore: 0.25)
        let lookingAtCam  = PhotoScore.make(qualityScore: 0.7, hasFace: true, faceYaw: 0.05, promptScore: 0.25)

        let awayScore = score(lookingAway,  category: .mugshot, isPromptMode: true, wantsLookingAway: true)
        let camScore  = score(lookingAtCam, category: .mugshot, isPromptMode: true, wantsLookingAway: true)

        XCTAssertGreaterThan(awayScore, camScore,
            "Looking-away photo should rank higher when prompt requests it")
    }

    func test_lookingAtCameraBoostWhenPromptWantsEyeContact() {
        let lookingAway  = PhotoScore.make(qualityScore: 0.7, hasFace: true, faceYaw: 0.4,  promptScore: 0.25)
        let lookingAtCam = PhotoScore.make(qualityScore: 0.7, hasFace: true, faceYaw: 0.05, promptScore: 0.25)

        let awayScore = score(lookingAway,  category: .mugshot, isPromptMode: true, wantsLookingAtCamera: true)
        let camScore  = score(lookingAtCam, category: .mugshot, isPromptMode: true, wantsLookingAtCamera: true)

        XCTAssertGreaterThan(camScore, awayScore,
            "Direct-gaze photo should rank higher when prompt requests eye contact")
    }

    // MARK: - Reference weight scales with count

    func test_moreReferencesMeansHigherDynamicWeight() {
        // With a perfect reference match (referenceScore = 1.0), a higher dynamic weight
        // should produce a higher final score than a lower weight.
        let score1Ref = scoreWithDynamicRefWeight(nRefs: 1, referenceScore: 1.0, qualityScore: 0.5)
        let score8Refs = scoreWithDynamicRefWeight(nRefs: 8, referenceScore: 1.0, qualityScore: 0.5)

        XCTAssertGreaterThan(score8Refs, score1Ref,
            "More reference photos should raise the dynamic reference weight and reward high-ref-sim photos more")
    }

    func test_referenceScoreHasNoEffectWhenZeroRefs() {
        // With no references, refWeight = 0 and referenceScore should have no effect
        let withRef    = PhotoScore.make(qualityScore: 0.5, referenceScore: 1.0)
        let withoutRef = PhotoScore.make(qualityScore: 0.5, referenceScore: nil)

        let s1 = processor.weightedScore(withRef,    category: .vacation, isPromptMode: false, dynamicRefWeight: 0)
        let s2 = processor.weightedScore(withoutRef, category: .vacation, isPromptMode: false, dynamicRefWeight: 0)

        XCTAssertEqual(s1, s2, accuracy: 0.001)
    }

    // MARK: - Prompt mode weights

    func test_promptMode_highPromptScoreRanksAboveLow() {
        let strongMatch = PhotoScore.make(qualityScore: 0.5, promptScore: 0.35)
        let weakMatch   = PhotoScore.make(qualityScore: 0.5, promptScore: 0.10)

        XCTAssertGreaterThan(
            score(strongMatch, category: .vacation, isPromptMode: true),
            score(weakMatch,   category: .vacation, isPromptMode: true)
        )
    }

    func test_promptMode_qualityStillMatters() {
        // Same prompt score but very different quality — quality must still influence
        let sharpLowPrompt  = PhotoScore.make(qualityScore: 0.95, promptScore: 0.20)
        let blurryHighPrompt = PhotoScore.make(qualityScore: 0.10, promptScore: 0.22)

        // sharpLowPrompt quality advantage should partially compensate
        let s1 = score(sharpLowPrompt,   category: .vacation, isPromptMode: true)
        let s2 = score(blurryHighPrompt, category: .vacation, isPromptMode: true)
        // Not asserting strict order here (prompt weight is 0.65, quality 0.35),
        // just assert neither is zero and they differ
        XCTAssertGreaterThan(s1, 0)
        XCTAssertGreaterThan(s2, 0)
        XCTAssertNotEqual(s1, s2, accuracy: 0.001)
    }

    // MARK: - Immediate feedback learning (Bayesian shrinkage)

    func test_learnedWeights_waitsForPositiveAndNegativeEvidence() {
        let singleDislike = makeFeedback(liked: false, quality: 0.20, exposure: 0.5, comp: 0.5, smile: 0.5)
        let weights = processor.learnedWeightMultipliers(from: [singleDislike])
        XCTAssertTrue(weights.isEmpty,
            "Preference weights should wait for both high- and low-rated evidence so a single negative-only rating does not oversteer future batches")
    }

    func test_learnedWeights_shrinkage_moreDataMeansStrongerSignal() {
        // Use a modest delta (liked=0.65, disliked=0.45, Δ=0.20) so the 1.40 cap isn't
        // hit until many events accumulate — this keeps all three weights distinct and
        // strictly increasing, proving the shrinkage formula actually scales with n.
        //
        // Math with k=5 pseudo-counts:
        //   n=1 (2 events): shrinkage=2/7≈0.29, mult ≈ 1.09
        //   n=5 (10 events): shrinkage=10/15≈0.67, mult ≈ 1.20
        //   n=30 (60 events): shrinkage=60/65≈0.92, mult ≈ 1.28
        func weights(n: Int) -> Float {
            let liked    = Array(repeating: makeFeedback(liked: true,  quality: 0.65), count: n)
            let disliked = Array(repeating: makeFeedback(liked: false, quality: 0.45), count: n)
            return processor.learnedWeightMultipliers(from: liked + disliked)["qualityScore"] ?? 1.0
        }
        let w1  = weights(n: 1)
        let w5  = weights(n: 5)
        let w30 = weights(n: 30)

        XCTAssertGreaterThan(w30, w5,
            "30 events should produce a stronger quality weight than 5 events for the same per-event signal")
        XCTAssertGreaterThan(w5, w1,
            "5 events should produce a stronger quality weight than 1 event for the same per-event signal")
        // All three should be > 1.0 — signal is pointing in the right direction from event #1
        XCTAssertGreaterThan(w1, 1.0,
            "Even 1 event should move the weight above 1.0 when liked photos are consistently sharper")
    }

    func test_learnedWeights_recentFeedbackCanOutweighStaleNoise() {
        let oldDate = Date().addingTimeInterval(-365 * 3 * 86_400)
        let staleLikes = (0..<100).map { _ in
            makeFeedback(liked: true, quality: 0.20, createdAt: oldDate)
        }
        let recentLikes = (0..<8).map { _ in
            makeFeedback(liked: true, quality: 0.80)
        }
        let recentDislikes = (0..<8).map { _ in
            makeFeedback(liked: false, quality: 0.20)
        }

        let weights = processor.learnedWeightMultipliers(from: staleLikes + recentLikes + recentDislikes)

        XCTAssertGreaterThan(weights["qualityScore"] ?? 1.0, 1.05,
            "Recent clear feedback should outweigh a large amount of stale contradictory history")
    }

    func test_learnedWeights_mixedSignalIsDampened() {
        let mixedLikes = (0..<20).map { _ in
            makeFeedback(liked: true, quality: 0.56)
        }
        let mixedDislikes = (0..<20).map { _ in
            makeFeedback(liked: false, quality: 0.50)
        }
        let clearLikes = (0..<20).map { _ in
            makeFeedback(liked: true, quality: 0.86)
        }
        let clearDislikes = (0..<20).map { _ in
            makeFeedback(liked: false, quality: 0.26)
        }

        let mixedWeight = processor.learnedWeightMultipliers(from: mixedLikes + mixedDislikes)["qualityScore"] ?? 1.0
        let clearWeight = processor.learnedWeightMultipliers(from: clearLikes + clearDislikes)["qualityScore"] ?? 1.0

        XCTAssertGreaterThan(mixedWeight, 1.0,
            "A small but consistent preference should still move the model gently")
        XCTAssertLessThan(mixedWeight - 1.0, (clearWeight - 1.0) * 0.35,
            "Mixed/low-separation feedback should be much weaker than a clear preference signal")
    }

    func test_learnedWeights_starRatingsScaleSignalStrength() {
        let strongLikes = (0..<12).map { _ in
            makeFeedback(liked: true, quality: 0.65, starRating: 5)
        }
        let strongDislikes = (0..<12).map { _ in
            makeFeedback(liked: false, quality: 0.45, starRating: 1)
        }
        let softLikes = (0..<12).map { _ in
            makeFeedback(liked: true, quality: 0.65, starRating: 4)
        }
        let softDislikes = (0..<12).map { _ in
            makeFeedback(liked: false, quality: 0.45, starRating: 2)
        }

        let strongWeight = processor.learnedWeightMultipliers(from: strongLikes + strongDislikes)["qualityScore"] ?? 1.0
        let softWeight = processor.learnedWeightMultipliers(from: softLikes + softDislikes)["qualityScore"] ?? 1.0

        XCTAssertGreaterThan(strongWeight, softWeight,
            "5-vs-1 feedback should train a stronger preference than 4-vs-2 feedback")
        XCTAssertGreaterThan(softWeight, 1.0,
            "4-vs-2 feedback should still train the model, just more gently")
    }

    func test_learnedWeights_threeStarRatingsStayNeutral() {
        let neutralHighQuality = (0..<10).map { _ in
            makeFeedback(liked: false, quality: 0.90, starRating: 3)
        }
        let neutralLowQuality = (0..<10).map { _ in
            makeFeedback(liked: false, quality: 0.10, starRating: 3)
        }

        let weights = processor.learnedWeightMultipliers(from: neutralHighQuality + neutralLowQuality)

        XCTAssertTrue(weights.isEmpty,
            "3-star feedback should be stored as acceptable/neutral, not as positive or negative training")
    }

    func test_learnedWeights_zeroEvents_returnsEmpty() {
        XCTAssertTrue(processor.learnedWeightMultipliers(from: []).isEmpty,
            "Zero feedback events should produce no weights")
    }

    // MARK: - Dimension hints (dislike reasons → keyword mapping)

    func test_dimensionHints_closedEyesReason_mapsToEyeConfidence() {
        let hints = processor.dimensionHintsFromReasons(["eyes are closed"])
        XCTAssertNotNil(hints["eyeOpenConfidence"],
            "'eyes are closed' should map to eyeOpenConfidence dimension hint")
        XCTAssertGreaterThan(hints["eyeOpenConfidence"]!, 1.30,
            "'closed eyes' phrase should trigger the stronger (1.40) eye hint, not just the generic 1.25")
    }

    func test_dimensionHints_crowdedBackground_mapsToCompositionAndBackground() {
        let hints = processor.dimensionHintsFromReasons(["too many people in the background"])
        XCTAssertNotNil(hints["compositionScore"],
            "'too many people in the background' should map to compositionScore")
        XCTAssertNotNil(hints["backgroundSharpness"],
            "'too many people in the background' should also map to backgroundSharpness")
    }

    func test_dimensionHints_crowd_mapsToComposition() {
        for phrase in ["crowded", "crowd", "lots of people", "people in background"] {
            let hints = processor.dimensionHintsFromReasons([phrase])
            XCTAssertNotNil(hints["compositionScore"],
                "'\(phrase)' should map to compositionScore")
        }
    }

    func test_dimensionHints_eyeHint_tightensPenaltyForClosedEyes() {
        // Without a hint, a closed-eye photo gets the standard eye penalty.
        // With an "eyeOpenConfidence" hint (1.40), penalty for closed eyes should be stronger.
        let closedEyes = PhotoScore.make(qualityScore: 0.7, hasFace: true, eyeOpenConfidence: 0.10)

        let scoreNoHint = processor.weightedScore(
            closedEyes, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, dimHints: [:]
        )
        let scoreWithHint = processor.weightedScore(
            closedEyes, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, dimHints: ["eyeOpenConfidence": 1.40]
        )
        XCTAssertGreaterThan(scoreNoHint, scoreWithHint,
            "Eye hint should make closed-eye photo score lower, not higher")
    }

    // MARK: - Score always in valid range

    func test_scoreAlwaysNonNegative() {
        let worst = PhotoScore.make(
            qualityScore: 0.0, hasFace: true, isSmiling: false,
            eyeOpenConfidence: 0.0, faceYaw: 0.5,
            categoryScore: 0.0, aestheticScore: 0.0,
            referenceScore: 0.0, promptScore: 0.0, feedbackScore: 0.0
        )
        for category in PhotoCategory.allCases {
            XCTAssertGreaterThanOrEqual(
                score(worst, category: category),
                0,
                "Score for \(category) must not be negative"
            )
        }
    }

    // MARK: - Helpers

    private func score(
        _ s: PhotoScore,
        category: PhotoCategory,
        isPromptMode: Bool = false,
        wantsLookingAway: Bool = false,
        wantsLookingAtCamera: Bool = false,
        dynamicRefWeight: Float = 0
    ) -> Float {
        processor.weightedScore(s, category: category, isPromptMode: isPromptMode,
                                dynamicRefWeight: dynamicRefWeight,
                                wantsLookingAway: wantsLookingAway,
                                wantsLookingAtCamera: wantsLookingAtCamera)
    }

    private func scoreWithDynamicRefWeight(nRefs: Int, referenceScore: Float, qualityScore: Float) -> Float {
        let rcRefWeight: Float = 0.40
        let ramp = min(Float(nRefs) / 8.0, 1.0)
        let dynWeight = 0.25 + ramp * (rcRefWeight - 0.25)
        let s = PhotoScore.make(qualityScore: qualityScore, referenceScore: referenceScore)
        return processor.weightedScore(s, category: .vacation, isPromptMode: false,
                                       dynamicRefWeight: dynWeight)
    }

    /// Creates a synthetic PhotoFeedback entry for testing `learnedWeightMultipliers`.
    /// No image is needed — we only care about the stored dimension scores.
    private func makeFeedback(
        liked: Bool,
        quality: Float = 0.5,
        exposure: Float = 0.5,
        comp: Float = 0.5,
        smile: Float = 0.5,
        eyes: Float = 0.5,
        color: Float = 0.5,
        reference: Float = 0.5,
        yaw: Float = 0,
        userFaceIdentified: Bool = false,
        createdAt: Date = Date(),
        starRating: Int = 0
    ) -> PhotoFeedback {
        let fb = PhotoFeedback(
            liked: liked,
            imageEmbedding: [],
            qualityScore: quality,
            exposureScore: exposure,
            compositionScore: comp,
            genuineSmileScore: smile,
            faceYaw: yaw,
            eyeOpenConfidence: eyes,
            colorHarmonyScore: color,
            referenceScore: reference,
            userFaceIdentified: userFaceIdentified,
            starRating: starRating
        )
        fb.createdAt = createdAt
        return fb
    }
}
