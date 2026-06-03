//
//  PersonaTests_Hinge.swift
//  VesperTests
//
//  Persona: A guy uploading 50 diverse photos to find his best Hinge profile shots.
//  He selected "Dating profile" purpose → isDatingMode = true.
//  He wants solo shots with eye contact, natural smile, and a good pose.
//
//  All tests call weightedScore directly with isDatingMode: true and isPromptMode: true
//  so the dating branch fires (it requires a non-nil promptScore).
//

import XCTest
@testable import Vesper

final class PersonaTests_Hinge: XCTestCase {

    let processor = BatchProcessor()

    // A neutral PromptIntent with no special overrides — matches the dating-profile scenario
    // where the user just wants a great portrait, not a specific creative angle.
    private let datingIntent = BatchProcessor.PromptIntent(
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

    // Convenience: call weightedScore in dating mode with all defaults that make sense
    // for a Hinge profile use case.
    private func datingScore(_ photo: PhotoScore) -> Float {
        processor.weightedScore(
            photo,
            category: .mugshot,
            isPromptMode: true,
            dynamicRefWeight: 0,
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            hasFaceContent: true,
            hasFeedback: false,
            intent: datingIntent,
            isDatingMode: true
        )
    }

    // MARK: - Test 1: Solo face beats group shot (soloBonus multiplier)

    // Dating profile 101: the main photo must clearly show *you*.
    // soloBonus for faceCount=1 is 1.20; for faceCount=3 it drops to 0.60 — a 2× difference
    // that should dominate even when everything else is identical.
    func test_soloFaceScoresHigherThanGroupPhoto_inDatingMode() {
        var solo = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        solo.faceCount = 1
        solo.poseScore = 0.7

        var group = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        group.faceCount = 3
        group.poseScore = 0.7

        XCTAssertGreaterThan(
            datingScore(solo), datingScore(group),
            "Solo shot (faceCount=1, soloBonus=1.20) must outscore group shot (faceCount=3, soloBonus=0.60)"
        )
    }

    // MARK: - Test 2: Smiling solo face beats non-smiling solo face

    // A warm, natural smile signals approachability — datingSmile applies a 1.15× multiplier
    // for smiling faces. Non-smiling gets no boost (multiplier stays at 1.0).
    func test_smilingFaceScoresHigherThanSeriousFace_inDatingMode() {
        var smiling = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        smiling.faceCount = 1
        smiling.poseScore = 0.7

        var serious = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: false,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        serious.faceCount = 1
        serious.poseScore = 0.7

        XCTAssertGreaterThan(
            datingScore(smiling), datingScore(serious),
            "Smiling face (datingSmile=1.15) must outscore non-smiling face (datingSmile=1.0) in dating mode"
        )
    }

    // MARK: - Test 3: Direct gaze beats looking away

    // Eye contact communicates confidence and presence — the #1 thing swipers notice.
    // faceYaw < 0.20 → datingEyeContact = 1.15; faceYaw > 0.20 → datingEyeContact = 0.85.
    func test_directGazeScoresHigherThanLookingAway_inDatingMode() {
        var eyeContact = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,   // clearly looking at camera
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        eyeContact.faceCount = 1
        eyeContact.poseScore = 0.7

        var lookingAway = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.35,   // clearly looking away
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        lookingAway.faceCount = 1
        lookingAway.poseScore = 0.7

        XCTAssertGreaterThan(
            datingScore(eyeContact), datingScore(lookingAway),
            "Direct gaze (faceYaw=0.05, datingEyeContact=1.15) must outscore looking away (faceYaw=0.35, datingEyeContact=0.85)"
        )
    }

    // MARK: - Test 4: Natural pose beats awkward pose

    // Body language matters on dating apps — a stiff or turned-away pose reads as insecure.
    // poseScore=0.8 → datingPose=1.0 (no penalty); poseScore=0.3 → datingPose=0.70+0.3*0.6=0.88.
    func test_naturalPoseScoresHigherThanAwkwardPose_inDatingMode() {
        var naturalPose = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        naturalPose.faceCount = 1
        naturalPose.poseScore = 0.8   // comfortable, open stance

        var awkwardPose = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        awkwardPose.faceCount = 1
        awkwardPose.poseScore = 0.3   // stiff or turned-away body angle

        XCTAssertGreaterThan(
            datingScore(naturalPose), datingScore(awkwardPose),
            "Natural pose (poseScore=0.8, datingPose=1.0) must outscore awkward pose (poseScore=0.3, datingPose=0.88)"
        )
    }

    // MARK: - Test 5: No-face photo scores lower than solo face photo

    // A landscape or object shot is a weak dating photo — soloBonus=0.70 when hasFace=false,
    // vs soloBonus=1.20 when faceCount=1.
    func test_noFaceScoresLowerThanSoloFace_inDatingMode() {
        var soloFace = PhotoScore.make(
            qualityScore: 0.7, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        soloFace.faceCount = 1
        soloFace.poseScore = 0.7

        var noFace = PhotoScore.make(
            qualityScore: 0.7, hasFace: false, isSmiling: false,
            eyeOpenConfidence: 0.8, faceYaw: 0.0,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        noFace.faceCount = 0
        noFace.poseScore = 0.5

        XCTAssertGreaterThan(
            datingScore(soloFace), datingScore(noFace),
            "Solo face (soloBonus=1.20) must outscore a faceless photo (soloBonus=0.70) in dating mode"
        )
    }

    // MARK: - Test 6: Sharp photo beats blurry photo even in dating mode

    // Quality still counts — a sharp, well-lit solo shot is always better than a blurry one.
    // qualityScore contributes a 0.30 weight inside the dating base calculation.
    func test_sharpSoloFaceScoresHigherThanBlurrySoloFace_inDatingMode() {
        var sharp = PhotoScore.make(
            qualityScore: 0.92, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        sharp.faceCount = 1
        sharp.poseScore = 0.7

        var blurry = PhotoScore.make(
            qualityScore: 0.18, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.9, faceYaw: 0.05,
            categoryScore: 0.6, aestheticScore: 0.6, promptScore: 0.25
        )
        blurry.faceCount = 1
        blurry.poseScore = 0.7

        XCTAssertGreaterThan(
            datingScore(sharp), datingScore(blurry),
            "Sharp solo face (qualityScore=0.92) must outscore blurry solo face (qualityScore=0.18) in dating mode"
        )
    }
}
