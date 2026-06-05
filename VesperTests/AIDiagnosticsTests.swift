//
//  AIDiagnosticsTests.swift
//  VesperTests
//

import XCTest
import UIKit
@testable import Vesper

final class AIDiagnosticsTests: XCTestCase {
    func test_allPhotosDeduplicatesAcrossPools() {
        let result = makeResult(compositeScore: 0.82)

        let photos = AIDiagnosticAnalyzer.allPhotos(
            topPicks: [result],
            runnerUps: [result],
            deleteCandidates: [],
            similars: [],
            ratings: [result.id: 5]
        )

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.rating, 5)
        XCTAssertEqual(photos.first?.pool, .topPicks)
    }

    func test_issuesFlagsObscuredEyesLabeledClosed() {
        var result = makeResult()
        result.eyeState = .closed
        result.eyeOpenConfidence = 0.10
        result.eyeOcclusionScore = 0.82

        let photos = AIDiagnosticAnalyzer.allPhotos(
            topPicks: [result],
            runnerUps: [],
            deleteCandidates: [],
            similars: [],
            ratings: [:]
        )
        let issues = AIDiagnosticAnalyzer.issues(for: photos)

        XCTAssertTrue(issues.contains { $0.id == "obscuredClosed" })
    }

    func test_issuesFlagsLargeBatchWithoutDeleteCandidates() {
        let topPicks = (0..<10).map { _ in makeResult() }
        let photos = AIDiagnosticAnalyzer.allPhotos(
            topPicks: topPicks,
            runnerUps: [],
            deleteCandidates: [],
            similars: [],
            ratings: [:]
        )

        let issues = AIDiagnosticAnalyzer.issues(for: photos)

        XCTAssertTrue(issues.contains { $0.id == "noDeletes" })
    }

    func test_issuesSeparateReferenceStyleFromIdentityMatch() {
        var result = makeResult()
        result.hasFace = true
        result.referenceScore = 0.72
        result.userFaceIdentified = false
        result.userFaceMatchConfidence = 0

        let photos = AIDiagnosticAnalyzer.allPhotos(
            topPicks: [result],
            runnerUps: [],
            deleteCandidates: [],
            similars: [],
            ratings: [:]
        )
        let issues = AIDiagnosticAnalyzer.issues(for: photos)

        XCTAssertTrue(issues.contains { $0.id == "styleWithoutIdentity" })
    }

    func test_issuesExplainOneSidedFeedbackNeedsContrast() {
        let result = makeResult()
        let photos = AIDiagnosticAnalyzer.allPhotos(
            topPicks: [result],
            runnerUps: [],
            deleteCandidates: [],
            similars: [],
            ratings: [result.id: 5]
        )
        let issues = AIDiagnosticAnalyzer.issues(for: photos)

        XCTAssertTrue(issues.contains { $0.id == "oneSidedFeedback" })
    }

    private func makeResult(compositeScore: Float = 0.6) -> PhotoResult {
        var result = PhotoResult(image: .test(), reasoning: "Test reasoning")
        result.compositeScore = compositeScore
        result.qualityScore = 0.6
        result.eyeState = .open
        result.eyeOpenConfidence = 0.8
        result.eyeSymmetryScore = 0.8
        result.eyeOcclusionScore = 0.0
        return result
    }
}
