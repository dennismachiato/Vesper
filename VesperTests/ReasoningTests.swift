//
//  ReasoningTests.swift
//  VesperTests
//
//  Tests that buildReasoning only claims things it's actually confident about.
//  The whole point of this file: prevent the hallucination bug where we said
//  "Eyes open and clear" on a photo with closed eyes.
//

import XCTest
@testable import Vesper

final class ReasoningTests: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - Eye claims

    func test_eyesOpenClaimed_onlyAbove75Confidence() {
        let confident = PhotoScore.make(hasFace: true, eyeOpenConfidence: 0.80)
        let r = reason(confident)
        XCTAssertTrue(r.contains("eyes look open") || r.contains("Eyes look") || r.contains("Open, alert eyes"),
            "Should cautiously claim eyes look open when confidence = 0.80; got: \(r)")
    }

    func test_eyesOpenNOTClaimed_below75Confidence() {
        let uncertain = PhotoScore.make(hasFace: true, eyeOpenConfidence: 0.60)
        let r = reason(uncertain)
        XCTAssertFalse(r.contains("Eyes look open") || r.contains("Open, alert eyes"),
            "Should NOT claim eyes open at uncertain confidence 0.60")
    }

    func test_eyesClosedWarning_below30Confidence() {
        let closed = PhotoScore.make(hasFace: true, eyeOpenConfidence: 0.20)
        XCTAssertTrue(reason(closed).contains("Eyes appear closed") || reason(closed).contains("eyes are closed"),
            "Should warn about closed eyes when confidence = 0.20")
    }

    func test_closedEyePreference_reasoningTreatsStrongPhotoAsIntentional() {
        var closed = PhotoScore.make(
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
        closed.genuineSmileScore = 0.90
        closed.colorHarmonyScore = 0.72

        let r = reason(closed, closedEyeTolerance: 1.0)

        XCTAssertFalse(r.contains("Eyes appear closed"), "Learned tolerance should avoid defect-style closed-eye wording; got: \(r)")
        XCTAssertTrue(r.contains("Closed-eye") || r.contains("closed-eye") || r.contains("Closed eyes") || r.contains("closed eyes"),
            "Strong tolerated closed-eye photos should be explained as intentional; got: \(r)")
    }

    func test_noEyeClaim_inUncertainRange() {
        // 0.30–0.75 should produce no eye-related claim at all
        for confidence: Float in [0.30, 0.45, 0.60, 0.74] {
            let score = PhotoScore.make(hasFace: true, eyeOpenConfidence: confidence)
            let r = reason(score)
            XCTAssertFalse(r.contains("Eyes look open") || r.contains("Open, alert eyes"), "No eye-open claim at confidence \(confidence)")
            XCTAssertFalse(r.contains("Eyes appear closed"),  "No eye-closed claim at confidence \(confidence)")
        }
    }

    func test_noEyeClaim_whenNoFace() {
        let noFace = PhotoScore.make(hasFace: false, eyeOpenConfidence: 0.10)
        let r = reason(noFace)
        XCTAssertFalse(r.contains("Eyes"), "No eye claim when there's no face")
    }

    // The core sunglasses/squint hallucination guard: even if confidence happens to sit
    // in the "looks open" or "looks closed" band, a `.unknown` state must produce no eye
    // claim. This is the test that should fail loudly if someone regresses the fix later.
    func test_unknownEyeState_getsUncertaintyInsteadOfOpenClosedClaim() {
        for confidence: Float in [0.10, 0.30, 0.50, 0.80, 0.95] {
            let s = PhotoScore.make(
                hasFace: true,
                eyeOpenConfidence: confidence,
                eyeState: .unknown
            )
            let r = reason(s)
            XCTAssertFalse(r.contains("Eyes look open") || r.contains("Open, alert eyes") || r.contains("Eyes appear closed"),
                "Unknown state should not produce definitive open/closed eye claims at confidence \(confidence); got: \(r)")
            XCTAssertTrue(r.contains("Eye state uncertain") || r.contains("Eye visibility is uncertain") || r.contains("Eyes are hard to read"),
                "Unknown state should explain uncertainty when eye visibility is surfaced; got: \(r)")
        }
    }

    func test_eyesOpenClaim_requiresOpenState_notJustConfidence() {
        // A .closed verdict with an inflated confidence (shouldn't happen in practice,
        // but the guard must still hold) must not produce an "Eyes open" claim.
        let s = PhotoScore.make(hasFace: true, eyeOpenConfidence: 0.95, eyeState: .closed)
        let r = reason(s)
        XCTAssertFalse(r.contains("Eyes open"),
            "State gate must override confidence — closed eyes never produce open-eye reasoning")
    }

    func test_groupIdentityReason_reflectsMatchConfidence() {
        let high = PhotoScore.make(
            hasFace: true, eyeState: .unknown,
            categoryScore: 0.2, aestheticScore: 0.2,
            faceCount: 3,
            userFaceIdentified: true, userFaceMatchConfidence: 0.82
        )
        let low = PhotoScore.make(
            hasFace: true, eyeState: .unknown,
            categoryScore: 0.2, aestheticScore: 0.2,
            faceCount: 3,
            userFaceIdentified: true, userFaceMatchConfidence: 0.42
        )

        XCTAssertTrue(reason(high).contains("Identified") || reason(high).contains("Found you"),
            "High-confidence identity match should use stronger language")
        XCTAssertTrue(reason(low).contains("Possible") || reason(low).contains("tentative"),
            "Low-confidence identity match should use tentative language")
    }

    // MARK: - Sharpness claims

    func test_sharpFocusClaimed_above75Quality() {
        let sharp = PhotoScore.make(qualityScore: 0.80)
        // Current copy: "Sharp and crisp" for 0.75..<0.85
        XCTAssertTrue(reason(sharp).contains("Sharp and crisp"))
    }

    func test_goodSharpnessClaimed_between55and75() {
        let ok = PhotoScore.make(qualityScore: 0.65)
        // Current copy: "Well-focused" for 0.65..<0.75
        XCTAssertTrue(reason(ok).contains("Well-focused"))
    }

    func test_noSharpnessClaim_below55() {
        let blurry = PhotoScore.make(qualityScore: 0.40)
        // At qualityScore 0.40, quality branch (qualContrib > 0.15 || qualityScore > 0.65)
        // is skipped — no sharpness-related claim should appear.
        let r = reason(blurry)
        XCTAssertFalse(r.contains("Sharp"))
        XCTAssertFalse(r.contains("Well-focused"))
        XCTAssertFalse(r.contains("Tack-sharp"))
    }

    // MARK: - Smile

    func test_naturalSmileClaimed_whenSmiling() {
        let smiling = PhotoScore.make(hasFace: true, isSmiling: true)
        XCTAssertTrue(reason(smiling).lowercased().contains("smile"),
            "Smiling photos should surface a smile/expression reason")
    }

    func test_noSmileClaim_whenNotSmiling() {
        let serious = PhotoScore.make(hasFace: true, isSmiling: false)
        XCTAssertFalse(reason(serious).contains("smile"))
    }

    // MARK: - Gaze direction

    func test_lookingAwayClaimed_highYaw() {
        let away = PhotoScore.make(hasFace: true, faceYaw: 0.40)
        // Current copy: "Strong profile angle" for yaw ≥ 0.40
        XCTAssertTrue(reason(away).contains("Strong profile angle"))
    }

    func test_directGazeClaimed_lowYaw() {
        let direct = PhotoScore.make(hasFace: true, faceYaw: 0.05)
        // Current copy: "Looking directly at camera" for yaw < 0.10
        XCTAssertTrue(reason(direct).contains("Looking directly at camera"))
    }

    // MARK: - Reference score

    func test_strongReferenceMatch_claimedAbove70() {
        let s = PhotoScore.make(referenceScore: 0.75)
        // Current copy: "Very close to your reference photos — strong style match" for rs > 0.72
        XCTAssertTrue(reason(s).contains("Very close to your reference photos"))
    }

    func test_styleMatch_between45and70() {
        let s = PhotoScore.make(referenceScore: 0.55)
        // Current copy: "Aligns well with your reference style" for rs > 0.55 (test at 0.55 is edge;
        // production uses > 0.55 so bump the fixture slightly)
        let s2 = PhotoScore.make(referenceScore: 0.60)
        XCTAssertTrue(reason(s).contains("Partially influenced") || reason(s2).contains("Aligns well with your reference style"))
    }

    func test_noReferenceClaim_below45() {
        let s = PhotoScore.make(referenceScore: 0.30)
        XCTAssertFalse(reason(s).contains("reference"), "No reference claim when score < 0.45")
    }

    // MARK: - Prompt mode

    func test_strongPromptMatch_above28() {
        let s = PhotoScore.make(promptScore: 0.30)
        // Current copy: "Strong match — {label}" for ps > 0.28
        XCTAssertTrue(reason(s, isPromptMode: true).contains("Strong match"))
    }

    func test_goodPromptMatch_between22and28() {
        let s = PhotoScore.make(promptScore: 0.25)
        // Current copy: "Good match — {label}" for 0.22 < ps ≤ 0.28
        XCTAssertTrue(reason(s, isPromptMode: true).contains("Good match"))
    }

    func test_closestMatch_below22() {
        let s = PhotoScore.make(promptScore: 0.15)
        // Current copy: "Best available match" for ps ≤ 0.22
        XCTAssertTrue(reason(s, isPromptMode: true).contains("Best available match"))
    }

    // MARK: - Fallback

    func test_fallbackReason_whenNothingQualifies() {
        // Low quality, no face, no reference, not prompt mode — must still return something.
        // Suppress every other reasoning branch so only the fallback remains:
        //   - categoryScore / aestheticScore below every threshold
        //   - negativeScore > 0.05 so "No technical flaws detected" stays silent
        //   - colorHarmonyScore low so no palette claim fires
        //   - backgroundSharpness mid-range so no DOF claim fires
        var s = PhotoScore.make(
            qualityScore: 0.30,
            hasFace: false,
            categoryScore: 0.30,
            aestheticScore: 0.30,
            referenceScore: nil
        )
        s.negativeScore = 0.10          // above the 0.05 "no flaws" threshold
        s.colorHarmonyScore = 0.50      // below the 0.75 palette threshold
        s.backgroundSharpness = 0.50    // between 0.25 and 0.70 → no DOF claim
        let r = reason(s)
        XCTAssertFalse(r.isEmpty, "Reasoning should never be empty")
        XCTAssertTrue(r.contains("Best overall balance"), "Should return fallback reason; got: \(r)")
    }

    func test_noAestheticClaims_inPromptMode() {
        // Aesthetic/category claims should not appear in prompt mode
        let s = PhotoScore.make(qualityScore: 0.5, categoryScore: 0.9, aestheticScore: 0.9, promptScore: 0.25)
        let r = reason(s, isPromptMode: true)
        XCTAssertFalse(r.contains("aesthetic match"))
        XCTAssertFalse(r.contains("category relevance"))
    }

    // MARK: - Helpers

    private func reason(_ s: PhotoScore, isPromptMode: Bool = false, closedEyeTolerance: Float = 0) -> String {
        processor.buildReasoning(
            s,
            isTopPick: true,
            isPromptMode: isPromptMode,
            promptText: "test",
            category: .mugshot,
            closedEyeTolerance: closedEyeTolerance
        )
    }
}
