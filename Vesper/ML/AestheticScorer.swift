//
//  AestheticScorer.swift
//  Vesper
//

import UIKit
import CoreImage
import CoreGraphics

/// Spatially-aware color statistics for a photo. Unlike a single CIAreaAverage pixel (whose mean
/// can't tell a flat gray wall from a high-contrast golden-hour portrait), this downsamples to a
/// small grid and derives both means AND distribution: real luminance contrast (std-dev) and a
/// 3-bin brightness histogram. Shared by AestheticScorer, ReferenceScorer, and ReferencePhotoService
/// so the three can't drift apart.
struct ColorStats {
    var brightness: Float        // mean luma 0..1
    var saturation: Float        // mean saturation 0..1
    var warmth: Float            // mean warmth 0..1 (1 = warm/red, 0 = cool/blue)
    var contrast: Float          // normalized luminance std-dev 0..1 (real contrast, not a proxy)
    var shadowFraction: Float    // fraction of pixels with luma < 0.33
    var midFraction: Float       // fraction with 0.33 <= luma < 0.66
    var highlightFraction: Float // fraction with luma >= 0.66

    nonisolated static let neutral = ColorStats(brightness: 0.5, saturation: 0.5, warmth: 0.5,
                                                contrast: 0.5, shadowFraction: 0.33,
                                                midFraction: 0.34, highlightFraction: 0.33)
}

enum ColorAnalyzer {
    /// Draws the image into a small RGBA grid and computes mean + distribution color statistics.
    nonisolated static func analyze(cgImage: CGImage, gridSide: Int = 32) -> ColorStats {
        let side = gridSide
        let bytesPerRow = side * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .neutral
        }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        guard let data = ctx.data else { return .neutral }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let count = side * side
        var sumB: Float = 0, sumS: Float = 0, sumW: Float = 0
        var lumas = [Float](repeating: 0, count: count)
        var shadow = 0, mid = 0, highlight = 0

        for i in 0..<count {
            let r = Float(pixels[i * 4 + 0]) / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            let brightness = (r + g + b) / 3.0
            let maxC = max(r, g, b); let minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            let warmth = min(max((r - b + 0.3) / 0.6, 0), 1)

            sumB += brightness; sumS += saturation; sumW += warmth
            lumas[i] = brightness
            if brightness < 0.33 { shadow += 1 }
            else if brightness < 0.66 { mid += 1 }
            else { highlight += 1 }
        }

        let n = Float(count)
        let meanB = sumB / n
        var variance: Float = 0
        for l in lumas { let d = l - meanB; variance += d * d }
        variance /= n
        // Std-dev of luma in 0..255 terms is sqrt(variance)*255; normalize by ~80 like the
        // existing grayscale-stddev pass so values land in a comparable 0..1 range.
        let contrast = min(sqrt(variance) * 255.0 / 80.0, 1.0)

        return ColorStats(
            brightness: meanB,
            saturation: sumS / n,
            warmth: sumW / n,
            contrast: contrast,
            shadowFraction: Float(shadow) / n,
            midFraction: Float(mid) / n,
            highlightFraction: Float(highlight) / n
        )
    }
}

class AestheticScorer {

    nonisolated func score(image: UIImage, aesthetic: AestheticStyle) -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }
        let s = ColorAnalyzer.analyze(cgImage: cgImage)

        switch aesthetic {
        case .brightAiry:
            // Wants: bright, highlight-heavy, soft low-saturation light. Penalize shadows.
            guard s.brightness > 0.35 else { return 0.1 }
            let brightnessScore = s.brightness > 0.55 ? s.brightness : s.brightness * 0.7
            let airyScore = s.highlightFraction
            let softnessScore = s.saturation < 0.45 ? (1.0 - s.saturation) : max(0, 1.0 - s.saturation * 1.5)
            let raw = brightnessScore * 0.40 + airyScore * 0.30 + softnessScore * 0.30
            return clamp(raw * (1.0 - s.shadowFraction * 0.5))

        case .darkMoody:
            // Wants: shadow-heavy, rich saturation, strong real contrast — cinematically dark.
            guard s.brightness < 0.65 else { return 0.1 }
            let darknessScore = s.shadowFraction
            let richnessScore = s.saturation > 0.2 ? s.saturation : s.saturation * 0.5
            return clamp(darknessScore * 0.45 + richnessScore * 0.25 + s.contrast * 0.30)

        case .warmGolden:
            // Wants: warm tones (reds/yellows), mid-to-high brightness, golden feel.
            let warmthScore = s.warmth > 0.5 ? s.warmth : s.warmth * 0.5
            let brightnessScore = s.brightness > 0.4 ? s.brightness : s.brightness * 0.6
            return clamp(warmthScore * 0.65 + brightnessScore * 0.35)

        case .cleanMinimal:
            // Wants: bright, low saturation, low visual noise (flat/low-contrast), highlight-leaning.
            guard s.brightness > 0.4 else { return 0.15 }
            let brightScore = s.brightness > 0.5 ? s.brightness : s.brightness * 0.6
            let cleanScore: Float = s.saturation < 0.25 ? 1.0
                                  : s.saturation < 0.4  ? (0.4 - s.saturation) / 0.15
                                  : 0.0
            let lowNoiseScore = 1.0 - s.contrast   // minimal = sparse, flat tonal range
            return clamp(brightScore * 0.35 + cleanScore * 0.40 + lowNoiseScore * 0.25)

        case .boldDramatic:
            // Wants: high saturation + strong real contrast — vibrant and striking.
            let satScore = s.saturation > 0.4 ? s.saturation : s.saturation * 0.4
            let contrastScore = s.contrast > 0.3 ? s.contrast : s.contrast * 0.5
            let warmthBonus = s.warmth * 0.10
            return clamp(satScore * 0.50 + contrastScore * 0.40 + warmthBonus)

        case .candidRaw:
            // Wants: natural, balanced mid-tones — slight imperfection is fine, no oversaturation.
            let naturalBrightness = 1.0 - abs(s.brightness - 0.45) * 1.2
            let naturalSat: Float = s.saturation < 0.6 ? 1.0 - s.saturation * 0.3 : 0.5
            return clamp(naturalBrightness * 0.45 + naturalSat * 0.35 + s.midFraction * 0.20)
        }
    }

    private nonisolated func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
