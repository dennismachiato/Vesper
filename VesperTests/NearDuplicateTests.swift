//
//  NearDuplicateTests.swift
//  VesperTests
//
//  Tests for BatchProcessor.suppressNearDuplicates.
//  Key contract: from a burst of near-identical photos, only the BEST-scoring
//  one should appear first — and duplicates must still be accessible in the tail.
//

import XCTest
@testable import Vesper

final class NearDuplicateTests: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - Basic dedup

    func test_identicalEmbeddings_onlyBestSurvivesFirst() {
        let sharedEmb: [Float] = randomUnitVector(dim: 16, seed: 1)

        // Two photos with identical CLIP embedding but different quality
        let better = PhotoScore.make(qualityScore: 0.85, categoryScore: 0.7, clipEmbedding: sharedEmb)
        let worse  = PhotoScore.make(qualityScore: 0.30, categoryScore: 0.4, clipEmbedding: sharedEmb)

        let result = processor.suppressNearDuplicates(
            [better, worse],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        // The first element should be the better-scoring photo
        XCTAssertEqual(result[0].qualityScore, 0.85, accuracy: 0.001,
            "The better photo should appear first in the deduplicated array")
        // The worse photo should still be present (just pushed to tail for runner-ups)
        XCTAssertEqual(result.count, 2, "Both photos should still be in the array")
    }

    func test_distinctEmbeddings_bothSurvive() {
        let emb1 = randomUnitVector(dim: 16, seed: 10)
        let emb2 = randomUnitVector(dim: 16, seed: 99)   // very different

        let a = PhotoScore.make(qualityScore: 0.7, clipEmbedding: emb1)
        let b = PhotoScore.make(qualityScore: 0.6, clipEmbedding: emb2)

        let result = processor.suppressNearDuplicates(
            [a, b],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        // Both should be in the 'kept' section (first two)
        XCTAssertEqual(result.count, 2)
        let topScores = Set(result.map { $0.qualityScore })
        XCTAssertTrue(topScores.contains(0.7) && topScores.contains(0.6),
            "Distinct photos should both appear")
    }

    func test_moderatelySimilarSameLocationFramesAreNotOneDuplicateCluster() {
        let emb1: [Float] = [1, 0, 0, 0]
        let emb2 = vectorWithCosineSimilarity(0.82)

        let a = PhotoScore.make(
            qualityScore: 0.70,
            hasFace: true,
            faceYaw: 0.05,
            compositionScore: 0.70,
            clipEmbedding: emb1,
            originalIndex: 0
        )
        let b = PhotoScore.make(
            qualityScore: 0.62,
            hasFace: true,
            faceYaw: 0.10,
            compositionScore: 0.68,
            clipEmbedding: emb2,
            originalIndex: 1
        )

        let result = processor.suppressNearDuplicates(
            [a, b],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        XCTAssertEqual(result.filter(\.isSimilar).count, 0,
            "Moderate same-location similarity should not collapse into one similar-photo cluster")
    }

    func test_burstOf4_onlyBestRanksFirst() {
        // Simulate 4 burst frames with the same embedding
        let burstEmb = randomUnitVector(dim: 16, seed: 5)
        let qualities: [Float] = [0.50, 0.75, 0.40, 0.65]
        let scores = qualities.enumerated().map { i, q in
            PhotoScore.make(qualityScore: q, clipEmbedding: burstEmb, originalIndex: i)
        }

        let result = processor.suppressNearDuplicates(
            scores,
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        XCTAssertEqual(result.count, 4, "All photos still present for runner-up fallback")
        XCTAssertEqual(result[0].qualityScore, 0.75, accuracy: 0.001,
            "Best burst frame (quality 0.75) should be the only kept photo in position 0")

        // The kept count is 1 (rest are suppressed to tail)
        // Kept photos are in first N slots; suppressed in the rest
        // Since all 4 have the same embedding, only 1 cluster → only 1 kept
        let keptScores = result.prefix(1).map { $0.qualityScore }
        XCTAssertTrue(keptScores.contains(0.75))
    }

    func test_noEmbedding_treatedAsOwnCluster() {
        // Photos without a CLIP embedding should not be deduplicated against each other
        let a = PhotoScore.make(qualityScore: 0.8, clipEmbedding: nil)
        let b = PhotoScore.make(qualityScore: 0.6, clipEmbedding: nil)

        let result = processor.suppressNearDuplicates(
            [a, b],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        XCTAssertEqual(result.count, 2)
        // Both should be in the kept section since they can't be compared
        XCTAssertEqual(result[0].qualityScore, 0.8, accuracy: 0.001)
        XCTAssertEqual(result[1].qualityScore, 0.6, accuracy: 0.001)
    }

    func test_singlePhoto_unchanged() {
        let s = PhotoScore.make(qualityScore: 0.7, clipEmbedding: randomUnitVector(dim: 16))
        let result = processor.suppressNearDuplicates(
            [s],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func test_emptyInput_returnsEmpty() {
        let result = processor.suppressNearDuplicates(
            [],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Mixed clusters

    func test_twoClusters_bothBestsAppearFirst() {
        let emb1 = randomUnitVector(dim: 16, seed: 7)
        let emb2 = randomUnitVector(dim: 16, seed: 77)

        // Cluster A: quality 0.8 and 0.5
        let a1 = PhotoScore.make(qualityScore: 0.80, clipEmbedding: emb1)
        let a2 = PhotoScore.make(qualityScore: 0.50, clipEmbedding: emb1)
        // Cluster B: quality 0.7 and 0.3
        let b1 = PhotoScore.make(qualityScore: 0.70, clipEmbedding: emb2)
        let b2 = PhotoScore.make(qualityScore: 0.30, clipEmbedding: emb2)

        let result = processor.suppressNearDuplicates(
            [a1, a2, b1, b2],
            category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0, wantsLookingAway: false, wantsLookingAtCamera: false, hasFeedback: false
        )

        // First 2 positions are the two cluster bests
        let topTwo = Set(result.prefix(2).map { $0.qualityScore })
        XCTAssertTrue(topTwo.contains(0.80), "Best of cluster A should be in top positions")
        XCTAssertTrue(topTwo.contains(0.70), "Best of cluster B should be in top positions")
        // Duplicates still in tail
        XCTAssertEqual(result.count, 4)
    }
}

private func vectorWithCosineSimilarity(_ similarity: Float) -> [Float] {
    let clamped = min(max(similarity, -1), 1)
    let y = sqrt(max(0, 1 - clamped * clamped))
    return [clamped, y, 0, 0]
}
