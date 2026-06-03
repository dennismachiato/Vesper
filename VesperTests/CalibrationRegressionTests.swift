//
//  CalibrationRegressionTests.swift
//  VesperTests
//
//  Golden-pair ranking tests for realistic Vesper scenarios. These do not use
//  real photos or ML models; they lock down how the scoring layer should order
//  known-good versus known-bad synthetic examples.
//

import XCTest
@testable import Vesper

final class CalibrationRegressionTests: XCTestCase {
    private let processor = BatchProcessor()

    func test_datingCalibration_openSoloWarmShotBeatsGroupBlink() {
        let best = PhotoScore.make(
            qualityScore: 0.82,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.92,
            eyeState: .open,
            faceYaw: 0.04,
            promptScore: 0.32,
            subjectHeight: 0.62,
            faceCount: 1
        )
        var groupBlink = PhotoScore.make(
            qualityScore: 0.82,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.12,
            eyeState: .closed,
            faceYaw: 0.08,
            promptScore: 0.32,
            subjectHeight: 0.62,
            faceCount: 4
        )
        groupBlink.poseScore = 0.45

        XCTAssertGreaterThan(
            datingScore(best),
            datingScore(groupBlink),
            "Dating profile scoring should prefer a clear solo open-eye photo over a group blink."
        )
    }

    func test_instagramCalibration_referenceStyleCanBeatSlightQualityAdvantage() {
        let onStyle = PhotoScore.make(
            qualityScore: 0.72,
            categoryScore: 0.70,
            aestheticScore: 0.78,
            referenceScore: 0.90,
            vibeScore: 0.75,
            trendScore: 0.70
        )
        let sharperOffStyle = PhotoScore.make(
            qualityScore: 0.90,
            categoryScore: 0.70,
            aestheticScore: 0.55,
            referenceScore: 0.25,
            vibeScore: 0.45,
            trendScore: 0.45
        )

        XCTAssertGreaterThan(
            score(onStyle, category: .vacation, dynamicRefWeight: 0.40),
            score(sharperOffStyle, category: .vacation, dynamicRefWeight: 0.40),
            "When references are available, an on-style photo should beat a slightly sharper off-style one."
        )
    }

    func test_cleanupCalibration_blurryClosedEyePhotoFallsBelowCleanPhoto() {
        var clean = PhotoScore.make(
            qualityScore: 0.78,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.88,
            eyeState: .open,
            categoryScore: 0.62,
            aestheticScore: 0.62
        )
        clean.exposureScore = 0.82

        var bad = PhotoScore.make(
            qualityScore: 0.18,
            hasFace: true,
            isSmiling: false,
            eyeOpenConfidence: 0.08,
            eyeState: .closed,
            categoryScore: 0.62,
            aestheticScore: 0.62
        )
        bad.exposureScore = 0.40

        XCTAssertGreaterThan(
            score(clean, category: .mugshot),
            score(bad, category: .mugshot),
            "Cleanup ranking should strongly demote blurry closed-eye photos."
        )
    }

    func test_groupCalibration_identifiedUserMetricsCanOutrankWrongPersonSmile() {
        let identifiedUser = PhotoScore.make(
            qualityScore: 0.76,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.86,
            eyeState: .open,
            faceYaw: 0.06,
            categoryScore: 0.68,
            aestheticScore: 0.70,
            referenceScore: 0.78,
            faceCount: 3,
            userFaceIdentified: true,
            userFaceMatchConfidence: 0.80
        )
        let wrongPersonEnergy = PhotoScore.make(
            qualityScore: 0.80,
            hasFace: true,
            isSmiling: true,
            eyeOpenConfidence: 0.86,
            eyeState: .open,
            faceYaw: 0.06,
            categoryScore: 0.72,
            aestheticScore: 0.70,
            referenceScore: 0.22,
            faceCount: 3,
            userFaceIdentified: false
        )

        XCTAssertGreaterThan(
            score(identifiedUser, category: .vacation, dynamicRefWeight: 0.35),
            score(wrongPersonEnergy, category: .vacation, dynamicRefWeight: 0.35),
            "Group photos should reward a confident user-face/reference match."
        )
    }

    func test_remoteConfigClamp_rejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(RemoteConfigService.clamp(.nan, min: 0, max: 1, fallback: 0.35), 0.35)
        XCTAssertEqual(RemoteConfigService.clamp(-4, min: 0, max: 1, fallback: 0.35), 0)
        XCTAssertEqual(RemoteConfigService.clamp(4, min: 0, max: 1, fallback: 0.35), 1)
        XCTAssertEqual(RemoteConfigService.clamp(0.42, min: 0, max: 1, fallback: 0.35), 0.42)
    }

    private func score(
        _ s: PhotoScore,
        category: PhotoCategory,
        dynamicRefWeight: Float = 0
    ) -> Float {
        processor.weightedScore(
            s,
            category: category,
            isPromptMode: false,
            dynamicRefWeight: dynamicRefWeight
        )
    }

    private func datingScore(_ s: PhotoScore) -> Float {
        processor.weightedScore(
            s,
            category: .mugshot,
            isPromptMode: true,
            promptText: "candid natural dating profile photo",
            dynamicRefWeight: 0,
            hasFaceContent: true,
            isDatingMode: true,
            datingAudience: "everyone"
        )
    }
}
