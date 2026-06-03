//
//  LibraryScanner.swift
//  Vesper
//
//  Scans the user's full photo library for deletable clutter. Runs in phases:
//
//    Phase 1 (instant) — metadata-only: screenshots, screen recordings
//    Phase 2 (fast)    — time-window clustering for similar/duplicate photos
//    Phase 3 (slow)    — AI-backed: blurry detection (Laplacian), receipt/document
//                        detection (Vision text recognition). Progressive — results
//                        stream in as each batch finishes.
//
//  All heavy work runs off the main actor. Published properties are updated on
//  main so SwiftUI picks up changes immediately.
//

import Photos
import UIKit
import Vision
import Observation

@Observable
@MainActor
final class LibraryScanner {

    // MARK: - Published state

    var groups: [CleanUpCategory: CleanUpGroup] = [:]
    var isScanning = false
    var scanPhase: String = ""
    var scanProgress: Float = 0           // 0.0 – 1.0, coarse

    /// Total reclaimable bytes across all groups.
    var totalReclaimableBytes: Int64 {
        groups.values.reduce(0) { $0 + $1.totalSizeBytes }
    }

    var totalReclaimableCount: Int {
        groups.values.reduce(0) { $0 + $1.count }
    }

    /// True once the full scan (all phases) has completed at least once.
    var scanComplete = false

    // MARK: - Scan entry point

    func startScan() async {
        guard !isScanning else { return }
        isScanning = true
        scanComplete = false
        groups = [:]

        // Phase 1 — metadata queries (instant)
        scanPhase = "Finding screenshots..."
        scanProgress = 0.05
        await scanScreenshots()

        scanPhase = "Finding screen recordings..."
        scanProgress = 0.15
        await scanScreenRecordings()

        // Phase 2 — time-window clustering (fast)
        scanPhase = "Finding similar photos..."
        scanProgress = 0.25
        await scanSimilarPhotos()

        // Phase 3 — AI-backed (progressive)
        scanPhase = "Checking for blurry photos..."
        scanProgress = 0.50
        await scanBlurryPhotos()

        scanPhase = "Looking for receipts..."
        scanProgress = 0.75
        await scanReceipts()

        // Done
        scanPhase = "Done"
        scanProgress = 1.0
        isScanning = false
        scanComplete = true
    }

    // MARK: - Phase 1: metadata queries

    private func scanScreenshots() async {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        let assets = assetsFromFetchResult(result)
        let size = await estimateTotalSize(assets)

        groups[.screenshots] = CleanUpGroup(
            id: CleanUpCategory.screenshots.rawValue,
            category: .screenshots,
            assets: assets,
            totalSizeBytes: size,
            isScanning: false
        )
    }

    private func scanScreenRecordings() async {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.videoScreenRecording.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .video, options: options)
        let assets = assetsFromFetchResult(result)
        let size = await estimateTotalSize(assets)

        groups[.screenRecordings] = CleanUpGroup(
            id: CleanUpCategory.screenRecordings.rawValue,
            category: .screenRecordings,
            assets: assets,
            totalSizeBytes: size,
            isScanning: false
        )
    }

    // MARK: - Phase 2: time-window clustering

    /// Groups photos taken within 10 seconds of each other into clusters.
    /// For each cluster of 3+ photos, all but the newest are marked as candidates.
    private func scanSimilarPhotos() async {
        // Exclude screenshots — they're already in their own category
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        let allPhotos = assetsFromFetchResult(fetchResult)
        guard allPhotos.count > 2 else { return }

        // Walk through photos and cluster by time proximity
        var clusters: [[PHAsset]] = []
        var currentCluster: [PHAsset] = [allPhotos[0]]

        for i in 1..<allPhotos.count {
            let prev = allPhotos[i - 1]
            let curr = allPhotos[i]

            if let prevDate = prev.creationDate, let currDate = curr.creationDate,
               currDate.timeIntervalSince(prevDate) <= 10 {
                // Same burst — add to cluster
                currentCluster.append(curr)
            } else {
                // Time gap — finalize previous cluster if it's big enough
                if currentCluster.count >= 3 {
                    clusters.append(currentCluster)
                }
                currentCluster = [curr]
            }
        }
        // Don't forget the last cluster
        if currentCluster.count >= 3 {
            clusters.append(currentCluster)
        }

        guard !clusters.isEmpty else { return }

        // For each cluster, mark all but the first (oldest) as candidates for deletion.
        // The user reviews and picks which to keep in the detail view.
        var candidates: [PHAsset] = []
        for cluster in clusters {
            // Keep the first photo (the earliest in the burst), surface the rest
            candidates.append(contentsOf: Array(cluster.dropFirst()))
        }

        let size = await estimateTotalSize(candidates)

        groups[.similarPhotos] = CleanUpGroup(
            id: CleanUpCategory.similarPhotos.rawValue,
            category: .similarPhotos,
            assets: candidates,
            totalSizeBytes: size,
            isScanning: false,
            clusters: clusters
        )
    }

    // MARK: - Phase 3a: blurry detection

    /// Checks non-screenshot photos from the last 6 months for sharpness.
    /// Uses Laplacian variance on 300×300 thumbnails — ~15-20 photos/second.
    private func scanBlurryPhotos() async {
        groups[.blurry] = CleanUpGroup(
            id: CleanUpCategory.blurry.rawValue,
            category: .blurry,
            assets: [],
            totalSizeBytes: 0,
            isScanning: true
        )

        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate > %@ AND (mediaSubtypes & %d) == 0",
            sixMonthsAgo as NSDate,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        let candidates = assetsFromFetchResult(fetchResult)

        // Process in batches of 30 to report progress and avoid memory pressure
        let batchSize = 30
        var blurry: [PHAsset] = []

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])

            let blurryBatch = await withTaskGroup(of: (PHAsset, Bool).self) { group in
                for asset in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (asset, false) }
                        let isBlurry = await self.isAssetBlurry(asset)
                        return (asset, isBlurry)
                    }
                }
                var results: [(PHAsset, Bool)] = []
                for await result in group { results.append(result) }
                return results
            }

            blurry.append(contentsOf: blurryBatch.filter(\.1).map(\.0))

            // Update progress within the blurry phase (0.50 → 0.75)
            let phaseProgress = Float(batchEnd) / Float(max(candidates.count, 1))
            scanProgress = 0.50 + phaseProgress * 0.25
        }

        let size = await estimateTotalSize(blurry)
        groups[.blurry] = CleanUpGroup(
            id: CleanUpCategory.blurry.rawValue,
            category: .blurry,
            assets: blurry,
            totalSizeBytes: size,
            isScanning: false
        )
    }

    // MARK: - Phase 3b: receipt / document detection

    /// Runs Vision text recognition on non-screenshot photos from the last 12 months.
    /// Images where recognised text covers a large portion of the frame are flagged as
    /// receipts / documents.
    private func scanReceipts() async {
        groups[.receipts] = CleanUpGroup(
            id: CleanUpCategory.receipts.rawValue,
            category: .receipts,
            assets: [],
            totalSizeBytes: 0,
            isScanning: true
        )

        let twelveMonthsAgo = Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? Date()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate > %@ AND (mediaSubtypes & %d) == 0",
            twelveMonthsAgo as NSDate,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Limit to a reasonable number — full OCR on the entire library is too slow
        options.fetchLimit = 2000

        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        let candidates = assetsFromFetchResult(fetchResult)

        let batchSize = 20
        var receipts: [PHAsset] = []

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])

            let receiptBatch = await withTaskGroup(of: (PHAsset, Bool).self) { group in
                for asset in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (asset, false) }
                        let isReceipt = await self.isAssetReceipt(asset)
                        return (asset, isReceipt)
                    }
                }
                var results: [(PHAsset, Bool)] = []
                for await result in group { results.append(result) }
                return results
            }

            receipts.append(contentsOf: receiptBatch.filter(\.1).map(\.0))

            let phaseProgress = Float(batchEnd) / Float(max(candidates.count, 1))
            scanProgress = 0.75 + phaseProgress * 0.25
        }

        let size = await estimateTotalSize(receipts)
        groups[.receipts] = CleanUpGroup(
            id: CleanUpCategory.receipts.rawValue,
            category: .receipts,
            assets: receipts,
            totalSizeBytes: size,
            isScanning: false
        )
    }

    // MARK: - Image analysis helpers

    /// Loads a 300×300 thumbnail and computes Laplacian variance.
    /// Photos with variance below a threshold are considered blurry.
    private nonisolated func isAssetBlurry(_ asset: PHAsset) async -> Bool {
        guard let image = await loadThumbnail(asset, size: CGSize(width: 300, height: 300)) else { return false }
        guard let cgImage = image.cgImage else { return false }

        let ciImage = CIImage(cgImage: cgImage)
        let laplacian = ciImage.applyingFilter("CILaplacian")
        let extent = laplacian.extent

        // Sample the centre to avoid edge artefacts
        let cropRect = extent.insetBy(dx: extent.width * 0.1, dy: extent.height * 0.1)
        guard !cropRect.isEmpty else { return false }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(laplacian.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: cropRect)]),
                   toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)

        // Higher = sharper. Threshold tuned empirically — below 12 is noticeably blurry.
        let sharpness = Float(bitmap[0])
        return sharpness < 12
    }

    /// Runs Vision text recognition and checks if text covers > 45% of the image area.
    private nonisolated func isAssetReceipt(_ asset: PHAsset) async -> Bool {
        guard let image = await loadThumbnail(asset, size: CGSize(width: 400, height: 400)) else { return false }
        guard let cgImage = image.cgImage else { return false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return false }

        guard let observations = request.results else { return false }

        // Compute total text bounding box area as a fraction of the image
        let totalTextArea = observations.reduce(Float(0)) { sum, obs in
            let box = obs.boundingBox
            return sum + Float(box.width * box.height)
        }

        // receipts / documents typically have > 45% text coverage and many observations
        return totalTextArea > 0.45 && observations.count > 8
    }

    // MARK: - Utility

    private nonisolated func loadThumbnail(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false   // don't download from iCloud for scanning

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Converts a PHFetchResult into a Swift array.
    private nonisolated func assetsFromFetchResult(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    /// Estimates total file size for a set of assets.
    /// Uses PHAssetResource file size when available, falls back to pixel-based estimate.
    private nonisolated func estimateTotalSize(_ assets: [PHAsset]) async -> Int64 {
        var total: Int64 = 0
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            if let resource = resources.first,
               let fileSize = resource.value(forKey: "fileSize") as? Int64 {
                total += fileSize
            } else {
                // Rough fallback: pixels × 3 bytes / ~8 compression
                let pixels = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
                total += max(pixels * 3 / 8, 50_000)   // at least 50 KB
            }
        }
        return total
    }

    // MARK: - Deletion

    /// Requests iOS to delete the given assets. Shows system confirmation dialog.
    nonisolated func deleteAssets(_ assets: [PHAsset]) async throws {
        let identifiers = assets.map(\.localIdentifier)
        try await PHPhotoLibrary.shared().performChanges {
            let assetsToDelete = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHAssetChangeRequest.deleteAssets(assetsToDelete)
        }
    }
}
