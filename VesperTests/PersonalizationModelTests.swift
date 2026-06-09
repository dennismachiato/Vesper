//
//  PersonalizationModelTests.swift
//  VesperTests
//

import XCTest
@testable import Vesper

final class PersonalizationModelTests: XCTestCase {
    func test_confidenceDropsWhenEyesAreOccludedAndUnknown() {
        let clear = ModelConfidenceEstimator.confidence(
            quality: 0.8,
            exposure: 0.8,
            composition: 0.8,
            eyeState: .open,
            eyeOpenConfidence: 0.9,
            eyeOcclusion: 0.05,
            identityConfidence: 0.85,
            hasFace: true,
            hasReference: true,
            hasFeedback: true
        )
        let occluded = ModelConfidenceEstimator.confidence(
            quality: 0.8,
            exposure: 0.8,
            composition: 0.8,
            eyeState: .unknown,
            eyeOpenConfidence: 0.5,
            eyeOcclusion: 0.9,
            identityConfidence: 0.45,
            hasFace: true,
            hasReference: true,
            hasFeedback: true
        )

        XCTAssertGreaterThan(clear, occluded)
    }

    func test_identityConfidenceUsesReferenceEvidenceAndMargin() {
        let tentative = ModelConfidenceEstimator.identityConfidence(
            similarity: 0.75,
            margin: 0.03,
            referenceCount: 1
        )
        let supported = ModelConfidenceEstimator.identityConfidence(
            similarity: 0.82,
            margin: 0.10,
            referenceCount: 5
        )

        XCTAssertGreaterThan(supported, tentative)
    }

    func test_pairwisePreferenceRewardsWinnerNeighborhood() {
        let winner: [Float] = [1, 0, 0, 0]
        let loser: [Float] = [0, 1, 0, 0]
        let feedback = PhotoFeedback(
            liked: true,
            imageEmbedding: winner,
            contrastEmbedding: loser,
            starRating: 5
        )
        let processor = BatchProcessor()

        let winnerScore = processor.pairwisePreferenceScore(
            for: winner,
            feedbackHistory: [feedback]
        )
        let loserScore = processor.pairwisePreferenceScore(
            for: loser,
            feedbackHistory: [feedback]
        )

        XCTAssertNotNil(winnerScore)
        XCTAssertNotNil(loserScore)
        XCTAssertGreaterThan(winnerScore ?? 0, loserScore ?? 1)
    }

    func test_similarFramesReceiveStableGroupMetadata() {
        let firstEmbedding: [Float] = [1, 0, 0, 0]
        let secondEmbedding: [Float] = [0.99, 0.1, 0, 0].normalised
        var first = PhotoScore.make(
            qualityScore: 0.85,
            hasFace: true,
            faceYaw: 0.1,
            compositionScore: 0.75,
            clipEmbedding: firstEmbedding,
            originalIndex: 0
        )
        first.genuineSmileScore = 0.8
        var second = PhotoScore.make(
            qualityScore: 0.45,
            hasFace: true,
            faceYaw: 0.12,
            compositionScore: 0.68,
            clipEmbedding: secondEmbedding,
            originalIndex: 1
        )
        second.genuineSmileScore = 0.3
        var scores = [first, second]

        BatchProcessor().applyBatchRelativeSignals(to: &scores)

        XCTAssertEqual(scores[0].similarGroupID, scores[1].similarGroupID)
        XCTAssertEqual(scores[0].similarGroupSize, 2)
        XCTAssertEqual(Set(scores.map(\.similarGroupRank)), Set([1, 2]))
    }

    func test_tasteControlsClampToSafeRange() {
        let controls = TasteControls(
            technicalQuality: 4,
            expression: 0,
            composition: 1,
            personalStyle: 2
        ).clamped()

        XCTAssertEqual(controls.technicalQuality, 1.25)
        XCTAssertEqual(controls.expression, 0.75)
        XCTAssertEqual(controls.composition, 1)
        XCTAssertEqual(controls.personalStyle, 1.25)
    }
}
