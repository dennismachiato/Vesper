//
//  ReferencePhotoIdentityTests.swift
//  VesperTests
//
//  Tests for deriving the user's face signature from reference photos.
//

import XCTest
@testable import Vesper

final class ReferencePhotoIdentityTests: XCTestCase {

    func test_userFaceEmbeddings_picksRecurringFaceAcrossGroupReferences() {
        let user = [1.0 as Float, 0.0, 0.0]
        let friend = [0.0 as Float, 1.0, 0.0]
        let other = [0.0 as Float, 0.0, 1.0]

        let p1 = makeReference(faceCount: 2, dominant: friend, allFaces: [friend, user])
        let p2 = makeReference(faceCount: 2, dominant: user, allFaces: [user, other])

        let embeddings = ReferencePhotoService.userFaceEmbeddings(from: [p1, p2])

        XCTAssertFalse(embeddings.isEmpty)
        XCTAssertEqual(embeddings.first ?? [], user, "The recurring face should become the user faceprint")
    }

    func test_userFaceEmbeddings_fallsBackOnlyToSoloReferencesWhenNoFaceRecurs() {
        let soloUser = [1.0 as Float, 0.0, 0.0]
        let groupDominant = [0.0 as Float, 1.0, 0.0]
        let groupOther = [0.0 as Float, 0.0, 1.0]

        let solo = makeReference(faceCount: 1, dominant: soloUser, allFaces: [soloUser])
        let group = makeReference(faceCount: 2, dominant: groupDominant, allFaces: [groupDominant, groupOther])

        let embeddings = ReferencePhotoService.userFaceEmbeddings(from: [solo, group])

        XCTAssertEqual(embeddings, [soloUser],
            "When no face recurs, only solo references are safe fallback anchors")
    }

    func test_userFaceEmbeddings_returnsEmptyWhenAllGroupReferencesAreAmbiguous() {
        let groupA = makeReference(
            faceCount: 2,
            dominant: [1.0 as Float, 0.0, 0.0],
            allFaces: [[1.0 as Float, 0.0, 0.0], [0.0 as Float, 1.0, 0.0]]
        )
        let groupB = makeReference(
            faceCount: 2,
            dominant: [0.0 as Float, 0.0, 1.0],
            allFaces: [[0.0 as Float, 0.0, 1.0], [0.6 as Float, 0.0, 0.0]]
        )

        let embeddings = ReferencePhotoService.userFaceEmbeddings(from: [groupA, groupB])

        XCTAssertTrue(embeddings.isEmpty,
            "Ambiguous group references with no recurring face should not create a user faceprint")
    }

    private func makeReference(
        faceCount: Int,
        dominant: [Float],
        allFaces: [[Float]]
    ) -> ReferencePhoto {
        ReferencePhoto(
            thumbnailData: Data(),
            brightness: 0.5,
            saturation: 0.5,
            warmth: 0.5,
            faceCount: faceCount,
            embedding: [0.0 as Float, 0.0, 0.0],
            faceCropEmbedding: dominant,
            allFaceCropEmbeddings: allFaces
        )
    }
}
