//
//  ReferenceScorer.swift
//  Vesper

import UIKit

class ReferenceScorer {
    /// Score using a pre-computed CLIP embedding (preferred — avoids a second sync CLIP call).
    /// Call this when the image embedding is already available from the batch pipeline.
    nonisolated func score(
        imageEmbedding: [Float],
        faceCount: Int,
        referenceEmbeddings: [[Float]],
        avgEmbedding: [Float],
        profile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                  avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)
    ) -> Float {
        let faceScore = faceCompositionScore(faceCount: faceCount, avgFaceCount: profile.avgFaceCount)
        guard !imageEmbedding.isEmpty else { return faceScore }
        let clipScore = clipMatchScore(imageEmbedding, referenceEmbeddings: referenceEmbeddings, avgEmbedding: avgEmbedding)
        return (clipScore * 0.75) + (faceScore * 0.25)
    }

    /// Legacy overload that computes the embedding on-the-fly (sync).
    /// Only used in contexts where the embedding isn't already available.
    func score(
        image: UIImage,
        faceCount: Int,
        referenceEmbeddings: [[Float]],
        avgEmbedding: [Float],
        profile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                  avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)
    ) -> Float {
        guard let imageEmb = CLIPEmbedder.shared?.embed(image: image), !imageEmb.isEmpty else {
            let colorSim = colorFallbackScore(image: image, profile: profile)
            let faceSim  = faceCompositionScore(faceCount: faceCount, avgFaceCount: profile.avgFaceCount)
            return (colorSim * 0.70) + (faceSim * 0.30)
        }
        let clipScore = clipMatchScore(imageEmb, referenceEmbeddings: referenceEmbeddings, avgEmbedding: avgEmbedding)
        let faceScore = faceCompositionScore(faceCount: faceCount, avgFaceCount: profile.avgFaceCount)
        return (clipScore * 0.75) + (faceScore * 0.25)
    }

    private nonisolated func clipMatchScore(_ imageEmb: [Float], referenceEmbeddings: [[Float]], avgEmbedding: [Float]) -> Float {
        if referenceEmbeddings.isEmpty {
            return CLIPEmbedder.cosineSimilarity(imageEmb, avgEmbedding)
        }
        // Max+avg blend: best single match + broad consistency across all references
        let sims = referenceEmbeddings.map { CLIPEmbedder.cosineSimilarity(imageEmb, $0) }
        let maxSim = sims.max() ?? 0
        let avgSim = sims.reduce(0, +) / Float(sims.count)
        return (maxSim * 0.55) + (avgSim * 0.45)
    }

    // MARK: - Face composition preference

    private nonisolated func faceCompositionScore(faceCount: Int, avgFaceCount: Float) -> Float {
        let candidate = Float(faceCount)
        if avgFaceCount < 1.5 {
            switch faceCount {
            case 0: return 1.0
            case 1: return 0.9
            case 2: return 0.4
            default: return 0.1
            }
        } else if avgFaceCount < 3 {
            return max(0, 1.0 - abs(candidate - avgFaceCount) * 0.3)
        } else {
            return max(0, 1.0 - abs(candidate - avgFaceCount) * 0.15)
        }
    }

    // MARK: - Color fallback (when CLIP is unavailable)

    private func colorFallbackScore(
        image: UIImage,
        profile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                  avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)
    ) -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }
        let stats = ColorAnalyzer.analyze(cgImage: cgImage)

        let db = stats.brightness - profile.brightness
        let ds = stats.saturation - profile.saturation
        let dw = stats.warmth     - profile.warmth
        return max(0, 1.0 - sqrt(db*db + ds*ds + dw*dw) / 1.73)
    }
}
