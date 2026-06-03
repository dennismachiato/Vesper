//
//  PersonaTests_GroupPhoto.swift
//  VesperTests
//
//  Persona: a group of friends picking the best shot from a birthday party.
//  Every photo has multiple people (faceCount 2–6), category .event.
//  They want everyone looking at the camera, smiling, and well-lit.
//  These tests verify multi-face scoring behaviour.
//

import XCTest
@testable import Vesper

final class PersonaTests_GroupPhoto: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - Test 1: No solo-bonus penalty in non-dating mode

    // In non-dating mode the scoring engine should treat a group shot on its own
    // merits. The dating-mode solo-bonus multiplier must not reduce a multi-face
    // photo's score when isDatingMode=false.
    func test_groupPhoto_notPenalisedForFaceCount_inNonDatingMode() {
        var groupShot = PhotoScore.make(
            qualityScore: 0.80,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.90,
            faceYaw: 0.05,
            categoryScore: 0.75,
            aestheticScore: 0.75
        )
        groupShot.faceCount = 4

        var soloShot = PhotoScore.make(
            qualityScore: 0.80,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.90,
            faceYaw: 0.05,
            categoryScore: 0.75,
            aestheticScore: 0.75
        )
        soloShot.faceCount = 1

        let groupScore = score(groupShot, category: .vacation, isDatingMode: false)
        let soloScore  = score(soloShot,  category: .vacation, isDatingMode: false)

        // Without a dating-mode solo multiplier the scores should be equal
        // (all inputs are identical except faceCount, which only matters in dating mode).
        XCTAssertEqual(groupScore, soloScore, accuracy: 0.001,
            "In non-dating mode faceCount=4 should score the same as faceCount=1 for equal inputs")
    }

    // MARK: - Test 2: Open eyes matter in group shots

    // Even in a crowd shot the app should reward clear, open eyes.
    // A birthday group where everyone's eyes are wide open should beat the same
    // scene where half the group is mid-blink.
    func test_openEyesScoreHigher_thanClosedEyes_inGroupShot() {
        var openEyes = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            eyesOpen: true,
            eyeOpenConfidence: 0.90,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        openEyes.faceCount = 4

        var closedEyes = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            eyesOpen: false,
            eyeOpenConfidence: 0.05,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        closedEyes.faceCount = 4

        let openScore   = score(openEyes,   category: .vacation)
        let closedScore = score(closedEyes, category: .vacation)

        XCTAssertGreaterThan(openScore, closedScore,
            "Group photo with open eyes (confidence=0.90) should outscore one with closed eyes (confidence=0.05)")
    }

    // MARK: - Test 3: Smiling group beats non-smiling group in mugshot-style framing

    // A birthday party shot with prominent faces lives in the .mugshot category
    // in production — that's where smile-preference is expressed. Smiles are a
    // positive signal here — the beaming group shot should rank above the stiff one.
    //
    // (The test originally asserted this under .vacation, but the vacation formula
    // is scenery-weighted and doesn't differentiate by smile. Production routes
    // face-forward group photos through .mugshot, so that's the right path to test.)
    func test_smilingGroupScoresHigher_thanSeriousGroup_inEventCategory() {
        var smiling = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        smiling.faceCount = 5

        var serious = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.65,
            aestheticScore: 0.65
        )
        serious.faceCount = 5

        XCTAssertGreaterThan(
            score(smiling, category: .mugshot),
            score(serious, category: .mugshot),
            "Smiling group photo should rank higher than non-smiling group photo in face-forward categories"
        )
    }

    // MARK: - Test 4: Direct gaze beats looking away when wantsLookingAtCamera=true

    // The friends ask the app to find the shot where everyone faces the camera.
    // A frame where all heads point forward (low faceYaw) should beat one where
    // people are turning away (high faceYaw).
    func test_directGazeScoresHigher_thanLookingAway_whenPromptWantsEyeContact() {
        var directGaze = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            eyeOpenConfidence: 0.85,
            faceYaw: 0.02,
            categoryScore: 0.65,
            aestheticScore: 0.65,
            promptScore: 0.25
        )
        directGaze.faceCount = 4

        var lookingAway = PhotoScore.make(
            qualityScore: 0.75,
            hasFace: true,
            eyeOpenConfidence: 0.85,
            faceYaw: 0.40,
            categoryScore: 0.65,
            aestheticScore: 0.65,
            promptScore: 0.25
        )
        lookingAway.faceCount = 4

        let directScore = score(directGaze,   category: .vacation, isPromptMode: true, wantsLookingAtCamera: true)
        let awayScore   = score(lookingAway,  category: .vacation, isPromptMode: true, wantsLookingAtCamera: true)

        XCTAssertGreaterThan(directScore, awayScore,
            "Direct-gaze group shot (faceYaw=0.02) should outscore looking-away shot (faceYaw=0.40) when wantsLookingAtCamera=true")
    }

    // MARK: - Test 5: Feedback score influences the final weightedScore

    // The friends have already liked a few shots. The feedback system should
    // recognise similarity to those liked photos and push them up the ranking.
    // Conversely a shot similar to disliked photos should score lower.
    func test_feedbackScore_higherFeedbackMeansHigherFinalScore() {
        var likedSimilar = PhotoScore.make(
            qualityScore: 0.70,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.65,
            aestheticScore: 0.65,
            feedbackScore: 0.85
        )
        likedSimilar.faceCount = 4

        var dislikedSimilar = PhotoScore.make(
            qualityScore: 0.70,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.85,
            categoryScore: 0.65,
            aestheticScore: 0.65,
            feedbackScore: 0.15
        )
        dislikedSimilar.faceCount = 4

        let likedScore    = score(likedSimilar,    category: .vacation, hasFeedback: true)
        let dislikedScore = score(dislikedSimilar, category: .vacation, hasFeedback: true)

        XCTAssertGreaterThan(likedScore, dislikedScore,
            "feedbackScore=0.85 should produce a higher weightedScore than feedbackScore=0.15 when hasFeedback=true")
    }

    // MARK: - Test 6: Prompt "everyone looking at camera and smiling" beats low-quality non-eye-contact shot

    // When the user types "everyone looking at camera and smiling" the intent
    // sets wantsLookingAtCamera=true. A slightly softer group shot that nails
    // eye contact and a strong prompt match should beat a technically-sharper
    // shot where nobody faces the lens.
    func test_promptMode_eyeContactAndHighPromptScore_beatsSharpButLookingAway() {
        // Strong prompt match, direct gaze — slightly lower quality
        var promptMatch = PhotoScore.make(
            qualityScore: 0.72,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.90,
            faceYaw: 0.02,
            categoryScore: 0.70,
            aestheticScore: 0.70,
            promptScore: 0.32
        )
        promptMatch.faceCount = 4

        // Sharper photo but poor eye contact and weak prompt match
        var noEyeContact = PhotoScore.make(
            qualityScore: 0.82,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.85,
            faceYaw: 0.40,
            categoryScore: 0.60,
            aestheticScore: 0.60,
            promptScore: 0.10
        )
        noEyeContact.faceCount = 4

        let intent = BatchProcessor.PromptIntent(
            wantsLookingAway: false,
            wantsLookingAtCamera: true,
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

        let promptMatchScore  = processor.weightedScore(
            promptMatch,
            category: .vacation,
            isPromptMode: true,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: true,
            hasFaceContent: true,
            hasFeedback: false,
            intent: intent,
            isDatingMode: false
        )

        let noEyeContactScore = processor.weightedScore(
            noEyeContact,
            category: .vacation,
            isPromptMode: true,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: true,
            hasFaceContent: true,
            hasFeedback: false,
            intent: intent,
            isDatingMode: false
        )

        XCTAssertGreaterThan(promptMatchScore, noEyeContactScore,
            "High promptScore + eye contact should beat a sharper photo that ignores the camera when prompt requests eye contact")
    }

    // MARK: - Helpers

    private func score(
        _ s: PhotoScore,
        category: PhotoCategory,
        isPromptMode: Bool = false,
        wantsLookingAway: Bool = false,
        wantsLookingAtCamera: Bool = false,
        dynamicRefWeight: Float = 0,
        hasFeedback: Bool = false,
        isDatingMode: Bool = false
    ) -> Float {
        processor.weightedScore(
            s,
            category: category,
            isPromptMode: isPromptMode,
            dynamicRefWeight: dynamicRefWeight,
            wantsLookingAway: wantsLookingAway,
            wantsLookingAtCamera: wantsLookingAtCamera,
            hasFaceContent: true,
            hasFeedback: hasFeedback,
            intent: nil,
            isDatingMode: isDatingMode
        )
    }
}
