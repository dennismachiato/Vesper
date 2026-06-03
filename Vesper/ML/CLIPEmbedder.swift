//
//  CLIPEmbedder.swift
//  Vesper
//

import CoreML
import UIKit

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

class CLIPEmbedder {
    private let model: mobileclip_s0_image

    nonisolated static let shared: CLIPEmbedder? = CLIPEmbedder()

    /// Serializes calls into the Core ML model. MLModel is documented as NOT
    /// thread-safe for concurrent `prediction(...)` — during batch scoring
    /// we deliberately fan out across many Tasks, so we funnel them back
    /// through this queue before touching the model.
    private let predictionQueue = DispatchQueue(label: "app.vesper.clip-image-embedder")

    init?() {
        guard let model = try? mobileclip_s0_image() else { return nil }
        self.model = model
    }

    // Returns a 512-dimensional embedding for the given image, or nil on failure.
    // Sync version — use only outside of concurrent task groups (e.g. feedback saving).
    func embed(image: UIImage) -> [Float]? {
        guard let pixelBuffer = pixelBuffer(from: image, size: CGSize(width: 256, height: 256)) else { return nil }
        let output: mobileclip_s0_imageOutput? = predictionQueue.sync {
            try? model.prediction(image: pixelBuffer)
        }
        guard let output else { return nil }

        let embedding = output.final_emb_1
        let count = embedding.count
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = embedding[i].floatValue }
        return normalized(result)
    }

    // Async version — suspends the calling Task instead of blocking its thread.
    // Use this inside concurrent task groups so the cooperative thread pool stays free
    // while waiting for the serial CLIP queue. Using the sync version inside 265 concurrent
    // tasks exhausts all cooperative threads and freezes progress at 0%.
    func embedAsync(image: UIImage) async -> [Float]? {
        guard let pixelBuffer = pixelBuffer(from: image, size: CGSize(width: 256, height: 256)) else { return nil }
        let sendableBuffer = SendablePixelBuffer(value: pixelBuffer)
        return await withCheckedContinuation { continuation in
            predictionQueue.async { [self] in
                guard let output = try? self.model.prediction(image: sendableBuffer.value) else {
                    continuation.resume(returning: nil)
                    return
                }
                let emb = output.final_emb_1
                var result = [Float](repeating: 0, count: emb.count)
                for i in 0..<emb.count { result[i] = emb[i].floatValue }
                continuation.resume(returning: self.normalized(result))
            }
        }
    }

    // Cosine similarity between two embeddings (both should be normalized).
    // Clamped to [0, 1]: normalized vectors dot to [-1, 1], but we treat negative
    // similarity as "unrelated" (0) for scoring purposes. NaN-safe.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).map(*).reduce(0, +)
        guard dot.isFinite else { return 0 }
        return min(1, max(0, dot))
    }

    private nonisolated func normalized(_ v: [Float]) -> [Float] {
        let magnitude = sqrt(v.map { $0 * $0 }.reduce(0, +))
        // Epsilon guard: protects against divide-by-near-zero on all-zero vectors
        // (which can happen if the model returns a degenerate embedding).
        guard magnitude > 1e-8 else { return v }
        return v.map { $0 / magnitude }
    }

    private nonisolated func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        guard let resized = image.resized(to: size),
              let cgImage = resized.cgImage else { return nil }

        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: NSNumber(value: true),
            kCVPixelBufferCGBitmapContextCompatibilityKey: NSNumber(value: true)
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB,
                            attrs, &pixelBuffer)

        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

private extension UIImage {
    nonisolated func resized(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
