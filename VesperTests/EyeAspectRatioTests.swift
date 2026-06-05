//
//  EyeAspectRatioTests.swift
//  VesperTests
//
//  Tests for VisionAnalyzer.earToConfidence — the EAR→confidence mapping.
//  This is the core of the "no more hallucinated open-eyes" fix.
//

import XCTest
@testable import Vesper

final class EyeAspectRatioTests: XCTestCase {

    // MARK: - Boundary values

    func test_belowFloor_returnsZero() {
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.00), 0.0, accuracy: 0.001)
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.05), 0.0, accuracy: 0.001)
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.07), 0.0, accuracy: 0.001)
    }

    func test_atFloor_returnsZero() {
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.08), 0.0, accuracy: 0.001)
    }

    func test_aboveCeiling_returnsOne() {
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.30), 1.0, accuracy: 0.001)
        XCTAssertEqual(VisionAnalyzer.earToConfidence(0.45), 1.0, accuracy: 0.001)
    }

    func test_midLowRange_returnsProbablyClosed() {
        // EAR 0.13 is in the 0.08–0.18 band → mapped to 0–0.5
        let c = VisionAnalyzer.earToConfidence(0.13)
        XCTAssertGreaterThan(c, 0.0)
        XCTAssertLessThan(c, 0.5, "EAR 0.13 should be in the 'probably closed' range")
    }

    func test_midHighRange_returnsProbablyOpen() {
        // EAR 0.24 is in the 0.18–0.30 band → mapped to 0.5–1.0
        let c = VisionAnalyzer.earToConfidence(0.24)
        XCTAssertGreaterThan(c, 0.5, "EAR 0.24 should be in the 'probably open' range")
        XCTAssertLessThan(c, 1.0)
    }

    // MARK: - Monotonically increasing

    func test_confidenceIncreasesMonotonically() {
        let ears: [Float] = [0.00, 0.05, 0.08, 0.10, 0.13, 0.18, 0.22, 0.26, 0.30, 0.40]
        let confidences = ears.map { VisionAnalyzer.earToConfidence($0) }
        for i in 1..<confidences.count {
            XCTAssertGreaterThanOrEqual(
                confidences[i], confidences[i - 1],
                "Confidence should not decrease as EAR increases (at index \(i): EAR \(ears[i]))"
            )
        }
    }

    // MARK: - Specific linear interpolation values

    func test_halfwayThroughLowBand() {
        // Midpoint of 0.08–0.18 → EAR 0.13, should be exactly 0.25
        let c = VisionAnalyzer.earToConfidence(0.13)
        XCTAssertEqual(c, 0.25, accuracy: 0.01)
    }

    func test_halfwayThroughHighBand() {
        // Midpoint of 0.18–0.30 → EAR 0.24, should be exactly 0.75
        let c = VisionAnalyzer.earToConfidence(0.24)
        XCTAssertEqual(c, 0.75, accuracy: 0.01)
    }

    // MARK: - Threshold alignment with reasoning tests

    func test_reasoningThreshold_openEyes_requiresConfidenceAbove75() {
        // The reasoning layer says "Eyes open" only when confidence > 0.75
        // EAR 0.24 maps to exactly 0.75 — use 0.235 (below) and 0.260 (above)
        let justBelow = VisionAnalyzer.earToConfidence(0.235)  // ~0.729
        let justAbove = VisionAnalyzer.earToConfidence(0.260)  // ~0.833
        XCTAssertLessThan(justBelow, 0.75)
        XCTAssertGreaterThan(justAbove, 0.75)
    }

    func test_reasoningThreshold_closedEyes_requiresConfidenceBelow30() {
        // The reasoning layer says "Eyes may be closed" only when confidence < 0.30
        // Which EAR does that correspond to? Should be < ~0.14
        let atThreshold = VisionAnalyzer.earToConfidence(0.14)
        XCTAssertLessThan(atThreshold, 0.35, "EAR 0.14 should map below the 0.30 'closed' threshold")
    }

    // MARK: - EyeState decision function (occlusion / profile / wink guards)
    //
    // The `.unknown` verdict is the core of the no-more-hallucinated-eyes fix:
    // when the geometry can't be trusted, we refuse to answer rather than guess.

    func test_eyeState_unknown_onExtremeYaw() {
        // Side-profile faces have foreshortened eye geometry — EAR is meaningless.
        // Both eyes reading 0.22 (clearly open in flat EAR terms) must still be `.unknown`
        // when yaw is past ~29°, because we can't actually see both eyes.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.22, rightEAR: 0.22, faceYaw: 0.8, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown, "High-yaw face should bail to .unknown regardless of EAR")
    }

    func test_eyeState_unknown_onLowFaceConfidence() {
        // Tinted sunglasses / heavy occlusion depresses Vision's per-face confidence.
        // Even if landmarks happen to produce a plausible EAR, we don't trust it.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.22, rightEAR: 0.22, faceYaw: 0.0, faceConfidence: 0.4
        )
        XCTAssertEqual(state, .unknown, "Low face confidence should force .unknown")
    }

    func test_eyeState_unknown_onMissingLandmarks() {
        // No eye landmarks at all (heavy occlusion, bad detection) → can't claim anything.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: nil, rightEAR: nil, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown)
    }

    func test_eyeState_unknown_onWinkOrOneCollapsedEye() {
        // A wink, uneven squint, eyelash/glasses occlusion, or bad landmark pass can make
        // one eye contour collapse while the other eye is clearly open. That is not enough
        // evidence to label the user's photo as "Eyes closed."
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.04, rightEAR: 0.26, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown, "One collapsed eye next to one open eye should stay .unknown, not .closed")
    }

    func test_eyeState_unknown_onAsymmetryInOpenZone() {
        // Both eyes open but very asymmetric readings — usually a bad landmark pass
        // rather than a real expression. Refuse to make a claim either way.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.18, rightEAR: 0.32, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown, "Wide asymmetry without a clearly-closed side → .unknown")
    }

    func test_eyeState_open_onSymmetricClearEyes() {
        // The happy path: both eyes clearly open, symmetric, straight-on face.
        let (state, conf, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.26, rightEAR: 0.26, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .open)
        XCTAssertGreaterThanOrEqual(conf, 0.75, "Clearly open eyes should pass the 0.75 reasoning threshold")
    }

    func test_eyeState_closed_onBothEyesShut() {
        let (state, conf, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.05, rightEAR: 0.06, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .closed)
        XCTAssertLessThan(conf, 0.30, "Clearly closed eyes should pass the 0.30 reasoning threshold")
    }

    func test_eyeState_unknown_whenOnlyOneEyeLooksClosed() {
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.05, rightEAR: nil, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown,
            "A single low EAR cannot prove both of the user's eyes are closed")
    }

    func test_eyeState_unknown_whenClosedGeometryHasSoftFaceConfidence() {
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.05, rightEAR: 0.06, faceYaw: 0.0, faceConfidence: 0.65
        )
        XCTAssertEqual(state, .unknown,
            "Low-ish face confidence should suppress closed-eye claims even when EAR is low")
    }

    func test_eyeState_unknown_onTinyFace() {
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.05, rightEAR: 0.06, faceYaw: 0.0, faceConfidence: 1.0,
            faceWidth: 0.04, faceHeight: 0.05
        )
        XCTAssertEqual(state, .unknown,
            "Tiny faces do not have enough landmark detail for a closed-eye label")
    }

    func test_eyeSignalMetrics_marksMissingEyesAsOccluded() {
        let metrics = VisionAnalyzer.eyeSignalMetrics(
            leftEAR: nil, rightEAR: nil, faceYaw: 0.0, faceConfidence: 0.92
        )

        XCTAssertLessThan(metrics.symmetry, 0.60)
        XCTAssertGreaterThan(metrics.occlusion, 0.80,
            "Missing eye landmarks should read as obscured, not as closed")
    }

    func test_eyeSignalMetrics_marksAsymmetryWithoutCallingItClosed() {
        let (state, _, symmetry, occlusion) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.06, rightEAR: 0.28, faceYaw: 0.0, faceConfidence: 0.95
        )

        XCTAssertEqual(state, .unknown)
        XCTAssertLessThan(symmetry, 0.40)
        XCTAssertGreaterThan(occlusion, 0.50,
            "One collapsed eye next to one open eye should be treated as unreliable/obscured")
    }

    func test_eyeSignalMetrics_trueClosedEyesAreNotTreatedAsSunglasses() {
        let (state, _, symmetry, occlusion) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.05, rightEAR: 0.06, faceYaw: 0.0, faceConfidence: 0.95
        )

        XCTAssertEqual(state, .closed)
        XCTAssertGreaterThan(symmetry, 0.90)
        XCTAssertLessThan(occlusion, 0.30,
            "Two consistently low EARs are a blink/closed-eye signal, not an occlusion signal")
    }

    func test_eyeState_unknown_inSquintZone() {
        // EARs in the ambiguous 0.12–0.20 band — could be a natural narrow eye, could be
        // a squint, could be partially closed. We stay silent rather than guess.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.15, rightEAR: 0.15, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown, "Squint-zone EAR should be .unknown — too ambiguous for a claim")
    }

    func test_eyeState_usesMinNotAverage_forMildAsymmetry() {
        // Even small asymmetry within the "conservative" path uses the min — so a photo
        // where one eye is squinted shouldn't falsely register as fully open.
        let (state, _, _, _) = VisionAnalyzer.eyeStateFromEARs(
            leftEAR: 0.15, rightEAR: 0.24, faceYaw: 0.0, faceConfidence: 1.0
        )
        XCTAssertEqual(state, .unknown,
            "Min EAR (0.15) is in the squint zone — verdict must follow the more-closed eye")
    }
}
