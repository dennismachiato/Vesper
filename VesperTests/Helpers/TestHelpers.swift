//
//  TestHelpers.swift
//  VesperTests
//
//  Factories for synthetic test data — no real photos or ML models needed.
//

import UIKit
import Foundation
@testable import Vesper

// MARK: - Solid-colour UIImage factory

extension UIImage {
    /// Creates a 10×10 solid-colour image. Fast, no file I/O.
    static func test(color: UIColor = .gray, size: CGSize = CGSize(width: 10, height: 10)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A batch of `count` distinct solid-colour test images.
    static func testBatch(count: Int) -> [UIImage] {
        (0..<count).map { i in
            let hue = CGFloat(i) / CGFloat(max(count, 1))
            return .test(color: UIColor(hue: hue, saturation: 0.8, brightness: 0.8, alpha: 1))
        }
    }
}

// MARK: - PhotoScore builder

extension PhotoScore {
    /// Build a synthetic PhotoScore with only the fields the test cares about.
    ///
    /// `eyeState` is derived from `eyeOpenConfidence` when not explicitly passed —
    /// ≥ 0.5 → `.open`, else `.closed`. Tests that care about the `.unknown` path
    /// (sunglasses / profile / wink / squint) should pass `eyeState: .unknown` directly.
    static func make(
        qualityScore: Float = 0.5,
        hasFace: Bool = false,
        isSmiling: Bool = false,
        eyesOpen: Bool = true,
        eyeOpenConfidence: Float = 0.8,
        eyeState: EyeState? = nil,
        faceYaw: Float = 0.0,
        exposureScore: Float = 0.5,
        compositionScore: Float = 0.5,
        poseScore: Float = 0.5,
        categoryScore: Float = 0.5,
        aestheticScore: Float = 0.5,
        referenceScore: Float? = nil,
        promptScore: Float? = nil,
        feedbackScore: Float? = nil,
        clipEmbedding: [Float]? = nil,
        subjectHeight: Float = 0.5,
        vibeScore: Float = 0.5,
        trendScore: Float = 0.5,
        negativeScore: Float = 0.0,
        faceCount: Int = 0,
        userFaceIdentified: Bool = false,
        userFaceMatchConfidence: Float = 0,
        originalIndex: Int = 0
    ) -> PhotoScore {
        var s = PhotoScore(image: .test(), qualityScore: qualityScore)
        s.hasFace = hasFace
        s.isSmiling = isSmiling
        // Production scoring reads genuineSmileScore (not the isSmiling Bool), so
        // cascade the flag into a meaningful value: smiling → Duchenne-range (0.80),
        // not smiling → clearly-neutral (0.15). Tests that need a specific
        // genuineSmileScore should set it on the returned PhotoScore directly.
        s.genuineSmileScore = isSmiling ? 0.80 : 0.15
        s.eyesOpen = eyesOpen
        s.eyeOpenConfidence = eyeOpenConfidence
        s.eyeState = eyeState ?? (eyeOpenConfidence >= 0.5 ? .open : .closed)
        s.faceYaw = faceYaw
        s.exposureScore = exposureScore
        s.compositionScore = compositionScore
        s.poseScore = poseScore
        s.categoryScore = categoryScore
        s.aestheticScore = aestheticScore
        s.referenceScore = referenceScore
        s.promptScore = promptScore
        s.feedbackScore = feedbackScore
        s.clipEmbedding = clipEmbedding
        s.subjectHeight = subjectHeight
        s.vibeScore = vibeScore
        s.trendScore = trendScore
        s.negativeScore = negativeScore
        s.faceCount = faceCount
        s.userFaceIdentified = userFaceIdentified
        s.userFaceMatchConfidence = userFaceMatchConfidence
        s.originalIndex = originalIndex
        return s
    }
}

// MARK: - Normalised vector helpers

extension Array where Element == Float {
    /// Returns a unit-length version of this vector.
    var normalised: [Float] {
        let mag = sqrt(self.map { $0 * $0 }.reduce(0, +))
        guard mag > 0 else { return self }
        return self.map { $0 / mag }
    }
}

/// Returns a random unit vector of `dim` dimensions, seeded for reproducibility.
func randomUnitVector(dim: Int, seed: UInt64 = 42) -> [Float] {
    var rng = seed
    var v = (0..<dim).map { _ -> Float in
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        // Use top 24 bits as an integer in [0, 2^24) → divide to get [0, 1) → shift to [-0.5, 0.5)
        // This avoids bitPattern tricks that can produce NaN/Inf.
        return Float(rng >> 40) / Float(1 << 24) - 0.5
    }
    let mag = sqrt(v.map { $0 * $0 }.reduce(0, +))
    if mag > 0 { v = v.map { $0 / mag } }
    return v
}
