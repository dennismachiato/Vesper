//
//  ReferencePhotoService.swift
//  Vesper
//

import SwiftUI
import SwiftData
import CoreImage
import UIKit
import Vision
import Accelerate
import OSLog

private struct ReferencePhotoAnalysis: Sendable {
    let thumbnailData: Data
    let brightness: Float
    let saturation: Float
    let warmth: Float
    let contrast: Float
    let sharpness: Float
    let avgFaceYaw: Float
    let faceCount: Int
    let embedding: [Float]
    let faceCropEmbedding: [Float]
    let allFaceCropEmbeddings: [[Float]]
}

@Observable
class ReferencePhotoService {
    private let context: ModelContext
    var photos: [ReferencePhoto] = []
    private nonisolated static var logger: Logger {
        Logger(subsystem: "Vesper", category: "ReferencePhoto")
    }

    init(context: ModelContext) {
        self.context = context
        load()
    }

    func load() {
        let descriptor = FetchDescriptor<ReferencePhoto>(sortBy: [SortDescriptor(\.createdAt)])
        do {
            photos = try context.fetch(descriptor)
        } catch {
            // Fetch shouldn't fail under normal conditions; log once so we notice in TestFlight.
            Self.logger.error("Fetch failed: \(error.localizedDescription, privacy: .private)")
            photos = []
        }
    }

    func add(image: UIImage) async {
        // All heavy analysis is kicked to a background task
        let result = await Task.detached(priority: .userInitiated) { () async -> ReferencePhotoAnalysis? in
            let (brightness, saturation, warmth, contrast) = Self.colorStats(image: image)
            let sharpness      = Self.laplacianSharpness(image: image)
            let faceCount      = Self.detectFaceCount(image: image)
            let avgFaceYaw     = Self.detectAvgFaceYaw(image: image)
            let embedding      = await CLIPEmbedder.shared?.embedAsync(image: image) ?? []
            let allFaceCrops   = await Self.allFaceCropEmbeddings(from: image)  // CLIP of every face crop
            let faceCropEmb    = allFaceCrops.first ?? []                 // dominant = largest face
            let thumbData      = Self.makeSquareThumbnail(image, side: 400)

            guard let data = thumbData else { return nil }

            return ReferencePhotoAnalysis(
                thumbnailData: data,
                brightness: brightness,
                saturation: saturation,
                warmth: warmth,
                contrast: contrast,
                sharpness: sharpness,
                avgFaceYaw: avgFaceYaw,
                faceCount: faceCount,
                embedding: embedding,
                faceCropEmbedding: faceCropEmb,
                allFaceCropEmbeddings: allFaceCrops
            )
        }.value

        guard let result else { return }
        let photo = ReferencePhoto(
            thumbnailData: result.thumbnailData,
            brightness: result.brightness,
            saturation: result.saturation,
            warmth: result.warmth,
            contrast: result.contrast,
            sharpness: result.sharpness,
            avgFaceYaw: result.avgFaceYaw,
            faceCount: result.faceCount,
            embedding: result.embedding,
            faceCropEmbedding: result.faceCropEmbedding,
            allFaceCropEmbeddings: result.allFaceCropEmbeddings
        )
        context.insert(photo)
        do {
            try context.save()
        } catch {
            // Disk full, permissions, or corrupted store. Photo insert will be rolled
            // back on next app launch; log so we can triage in TestFlight.
            Self.logger.error("Save after insert failed: \(error.localizedDescription, privacy: .private)")
        }
        load()
    }

    func remove(_ photo: ReferencePhoto) {
        context.delete(photo)
        do {
            try context.save()
        } catch {
            Self.logger.error("Save after delete failed: \(error.localizedDescription, privacy: .private)")
        }
        load()
    }

    // MARK: - Taste profile

    // Extended to include sharpness + contrast preference
    var tasteProfile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                       avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)? {
        guard !photos.isEmpty else { return nil }
        let count = Float(photos.count)
        let b  = photos.map(\.brightness).reduce(0, +) / count
        let s  = photos.map(\.saturation).reduce(0, +) / count
        let w  = photos.map(\.warmth).reduce(0, +) / count
        let f  = photos.map { Float($0.faceCount) }.reduce(0, +) / count
        let sh = photos.map(\.sharpness).reduce(0, +) / count
        let co = photos.map(\.contrast).reduce(0, +) / count
        let yw = photos.map(\.avgFaceYaw).reduce(0, +) / count
        return (b, s, w, f, sh, co, yw)
    }

    // MARK: - User face identity (recurring face across references)

    /// Cosine similarity above which two face crops are treated as the same person. CLIP isn't an
    /// identity model, so this is deliberately moderate — recurrence across references, not a single
    /// pairwise score, is what makes the result trustworthy.
    private nonisolated static let sameFaceThreshold: Float = 0.75

    /// The user's face signature(s), derived as the face that RECURS across reference photos.
    ///
    /// References can be selfies, IG photos, or screenshots — possibly group shots where the user
    /// isn't the largest face. The one constant across all of them is the user, so we pick the face
    /// that finds a strong match in the most *other* references, and return that face plus its
    /// matches (multiple angles → better identification in batch photos).
    ///
    /// Falls back to dominant face crops only when the references are safe enough to trust:
    /// a single usable reference, or solo-face references when recurrence cannot be established.
    /// If every reference is an ambiguous group shot and no face recurs, returns [] so batch
    /// scoring falls back to dominant-subject behavior instead of learning the wrong person.
    nonisolated static func userFaceEmbeddings(from photos: [ReferencePhoto]) -> [[Float]] {
        // Per-reference list of face embeddings (only references that have at least one face).
        let perReference: [[[Float]]] = photos
            .map { $0.allFaceCropEmbeddings.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }

        guard perReference.count >= 2 else {
            // 0 or 1 usable reference — can't establish recurrence. Use the dominant crop(s).
            return perReference.first.map { [$0[0]] } ?? []
        }

        var bestSeed: [Float]? = nil
        var bestMatches: [[Float]] = []
        var bestCoverage = 0
        var bestScore: Float = 0

        for (ri, faces) in perReference.enumerated() {
            for seed in faces {
                var coverage = 0
                var scoreSum: Float = 0
                var matches: [[Float]] = []
                for (rj, otherFaces) in perReference.enumerated() where rj != ri {
                    // Best matching face for this seed within the other reference.
                    var bestSim: Float = -1
                    var bestEmb: [Float] = []
                    for other in otherFaces {
                        let sim = CLIPEmbedder.cosineSimilarity(seed, other)
                        if sim > bestSim { bestSim = sim; bestEmb = other }
                    }
                    if bestSim >= sameFaceThreshold {
                        coverage += 1
                        scoreSum += bestSim
                        matches.append(bestEmb)
                    }
                }
                // Prefer the seed recurring in the most references; tie-break on total similarity.
                if coverage > bestCoverage || (coverage == bestCoverage && scoreSum > bestScore) {
                    bestCoverage = coverage
                    bestScore = scoreSum
                    bestSeed = seed
                    bestMatches = matches
                }
            }
        }

        // Require the winner to appear in at least one other reference (spans >= 2 references).
        if let seed = bestSeed, bestCoverage >= 1 {
            return [seed] + bestMatches
        }

        // No recurring face found. Only solo references are safe fallback anchors; dominant
        // faces from group references can easily be a friend, date, or bystander.
        let soloDominants = photos
            .filter { $0.faceCount == 1 }
            .map(\.faceCropEmbedding)
            .filter { !$0.isEmpty }
        return soloDominants
    }

    // Average CLIP embedding across all reference photos — the semantic taste fingerprint
    var averageEmbedding: [Float]? {
        let embeddings = photos.map(\.embedding).filter { !$0.isEmpty }
        guard !embeddings.isEmpty else { return nil }
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings { for i in 0..<dim { avg[i] += emb[i] } }
        let n = Float(embeddings.count)
        avg = avg.map { $0 / n }
        let magnitude = sqrt(avg.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return avg }
        return avg.map { $0 / magnitude }
    }

    // MARK: - Thumbnail

    /// Produces a sharp square JPEG at `side` points (device-independent — stored pixels).
    /// Center-crops so SwiftUI's aspectRatio(1) fill never upscales the image.
    private nonisolated static func makeSquareThumbnail(_ image: UIImage, side: CGFloat) -> Data? {
        let scale = image.scale
        let pixelSide = side  // store at `side` pixels regardless of scale factor

        // Normalize orientation first
        let normalized: UIImage
        if image.imageOrientation == .up {
            normalized = image
        } else {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            normalized = renderer.image { _ in image.draw(at: .zero) }
        }

        guard let cgImg = normalized.cgImage else { return nil }
        let srcW = CGFloat(cgImg.width)
        let srcH = CGFloat(cgImg.height)

        // Center-crop to square in pixel space
        let cropSide = min(srcW, srcH)
        let cropRect = CGRect(
            x: (srcW - cropSide) / 2,
            y: (srcH - cropSide) / 2,
            width: cropSide,
            height: cropSide
        )
        guard let cropped = cgImg.cropping(to: cropRect) else { return nil }

        // Scale down to target size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // pixel-exact — 1 pixel = 1 point in stored data
        let squareImg = UIGraphicsImageRenderer(size: CGSize(width: pixelSide, height: pixelSide),
                                                format: format).image { _ in
            UIImage(cgImage: cropped, scale: scale, orientation: .up)
                .draw(in: CGRect(origin: .zero, size: CGSize(width: pixelSide, height: pixelSide)))
        }
        return squareImg.jpegData(compressionQuality: 0.88)
    }

    // MARK: - Feature extraction

    /// Crops every detected face (with 35% padding for context, largest first) and returns each
    /// one's CLIP embedding. These "face signatures" let the user be identified later as the face
    /// that recurs across reference photos — robust to references that are IG/group shots or
    /// screenshots where the user isn't the biggest face. Returns [] when no face is detected.
    /// Tiny faces (< 4% of the frame width) are skipped — likely background bystanders, not the
    /// reference subject, and too small to embed reliably.
    private nonisolated static func allFaceCropEmbeddings(from image: UIImage) async -> [[Float]] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch { return [] }
        guard let faces = request.results, !faces.isEmpty else { return [] }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let pad: CGFloat = 0.35

        let ordered = faces
            .filter {
                $0.boundingBox.width >= 0.06 &&
                $0.boundingBox.height >= 0.06 &&
                $0.confidence >= 0.70 &&
                (abs($0.yaw?.floatValue ?? 0) <= 0.60)
            }
            .sorted { $0.boundingBox.width > $1.boundingBox.width }

        var embeddings: [[Float]] = []
        for face in ordered {
            let box = face.boundingBox
            // Vision bbox is y-up; CGImage is y-down
            let flippedY = 1.0 - box.maxY
            let cropRect = CGRect(
                x: max(0, (box.minX - box.width * pad) * w),
                y: max(0, (flippedY - box.height * pad) * h),
                width: min(w, box.width * (1 + 2 * pad) * w),
                height: min(h, box.height * (1 + 2 * pad) * h)
            ).intersection(CGRect(x: 0, y: 0, width: w, height: h))

            guard cropRect.width > 10, cropRect.height > 10,
                  let cropped = cgImage.cropping(to: cropRect),
                  let emb = await CLIPEmbedder.shared?.embedAsync(image: UIImage(cgImage: cropped)),
                  !emb.isEmpty else { continue }
            embeddings.append(emb)
        }
        return embeddings
    }

    private nonisolated static func detectFaceCount(image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            Self.logger.error("Face-rect Vision request failed: \(error.localizedDescription, privacy: .private)")
            return 0
        }
        return request.results?.count ?? 0
    }

    private nonisolated static func detectAvgFaceYaw(image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0 }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            Self.logger.error("Face-landmarks Vision request failed: \(error.localizedDescription, privacy: .private)")
            return 0
        }
        guard let faces = request.results, !faces.isEmpty else { return 0 }
        let yaws = faces.compactMap { $0.yaw?.floatValue }
        guard !yaws.isEmpty else { return 0 }
        return yaws.reduce(0, +) / Float(yaws.count)
    }

    private nonisolated static func colorStats(image: UIImage) -> (brightness: Float, saturation: Float, warmth: Float, contrast: Float) {
        guard let cgImage = image.cgImage else { return (0.5, 0.5, 0.5, 0.5) }
        let stats = ColorAnalyzer.analyze(cgImage: cgImage)
        return (stats.brightness, stats.saturation, stats.warmth, stats.contrast)
    }

    /// Laplacian sharpness on a downscaled version of the image (0 = soft/blurry, 1 = sharp)
    private nonisolated static func laplacianSharpness(image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }

        // Downscale to 256×256 before Laplacian for speed
        let side = 256
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        guard let data = ctx.data else { return 0.5 }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var laplacianVar: Float = 0
        var sumSq: Float = 0
        var count = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Float(pixels[y * side + x])
                let lap = 4 * center
                    - Float(pixels[(y-1) * side + x])
                    - Float(pixels[(y+1) * side + x])
                    - Float(pixels[y * side + (x-1)])
                    - Float(pixels[y * side + (x+1)])
                sumSq += lap * lap
                count += 1
            }
        }
        laplacianVar = count > 0 ? sumSq / Float(count) : 0
        // Empirically, sharp photos score 1000+; blurry < 100
        return min(laplacianVar / 2000.0, 1.0)
    }
}
