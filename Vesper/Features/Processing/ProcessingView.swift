//
//  ProcessingView.swift
//  Vesper
//
//  Created by Dennis Mach on 4/2/26.
//

import SwiftUI
import PhotosUI
import Combine

private enum ProcessingPhase: Equatable {
    case loading    // downloading from iCloud / camera roll
    case analyzing  // on-device AI scoring + sorting
}

/// Reference-backed image store. Holds the UIImage arrays outside SwiftUI's
/// value-type @State so they survive view-tree rebuilds (device rotation,
/// size class changes) without being copied or re-allocated. This is what
/// prevents the rotation-OOM described in the audit.
@MainActor
private final class ImageBuffer: ObservableObject {
    @Published var loaded: [UIImage] = []
    @Published var ordered: [(index: Int, image: UIImage)] = []

    func reset() {
        loaded.removeAll(keepingCapacity: false)
        ordered.removeAll(keepingCapacity: false)
    }

    func append(_ image: UIImage, at originalIndex: Int) {
        loaded.append(image)
        ordered.append((index: originalIndex, image: image))
    }
}

struct ProcessingView: View {
    let items: [PhotosPickerItem]
    let assetIdentifiers: [String]        // parallel to items — PHAsset localIdentifier per photo
    let pickCount: Int
    let category: PhotoCategory
    let aesthetics: [AestheticStyle]
    let tasteProfile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                       avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)?
    let referenceEmbeddings: [[Float]]    // individual per-reference CLIP embeddings
    let avgEmbedding: [Float]?            // centroid fallback
    let promptEmbedding: [Float]?
    let promptText: String
    let isPromptMode: Bool
    let isDatingMode: Bool
    /// When true, the user opted to skip prompt/category and lean entirely on
    /// their stored reference photos as the taste signal.
    var isReferenceDriven: Bool = false
    let datingVibe: String
    let datingAudience: String
    let likedEmbeddings: [(embedding: [Float], date: Date)]
    let neutralEmbeddings: [(embedding: [Float], date: Date)]
    let dislikedEmbeddings: [(embedding: [Float], date: Date)]
    let dislikeReasonEmbeddings: [(embedding: [Float], date: Date)]
    let contrastEmbeddings: [(embedding: [Float], date: Date)]
    let feedbackHistory: [PhotoFeedback]
    let dislikeReasons: [String]
    let purposeTag: String
    /// CLIP embeddings of face crops from reference photos — passed to BatchProcessor so it can
    /// identify which face in each photo belongs to the user.
    var userFaceEmbeddings: [[Float]] = []
    let requireUniquePicks: Bool
    let onComplete: ([PhotoResult], [PhotoResult], [PhotoResult], [PhotoResult]) -> Void
    /// Pre-loaded images from a batch rerun — when set, the download phase is skipped
    /// and analysis starts immediately. `items` should be empty in this case.
    var preloadedImages: [UIImage]? = nil

    @State private var phase: ProcessingPhase = .loading
    @StateObject private var buffer = ImageBuffer()
    @State private var processingTask: Task<Void, Never>? = nil
    @State private var currentError: AppError? = nil
    @State private var analysisCompleted: Int = 0
    @State private var analysisTotal: Int = 0
    /// True once loading has been stuck at 0 for ≥10 s — triggers the iCloud advice banner.
    @State private var showICloudHint: Bool = false
    @State private var iCloudHintTask: Task<Void, Never>? = nil
    @Environment(\.dismiss) private var dismiss

    // Convenience mirrors — keep existing call sites readable.
    private var loadedImages: [UIImage] { buffer.loaded }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 5)

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            if let error = currentError {
                ErrorView(error: error, onRetry: {
                    currentError = nil
                    buffer.reset()
                    phase = .loading
                    processingTask = Task { await run() }
                }, onDismiss: {
                    dismiss()
                })
            } else {
                VStack(spacing: 0) {
                    Spacer()
                    if phase == .loading {
                        loadingView
                    } else {
                        analyzingView
                    }
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
        .onAppear {
            guard processingTask == nil else { return }
            processingTask = Task { await run() }
            // After 10 s with 0 photos loaded, surface actionable iCloud advice
            iCloudHintTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !Task.isCancelled && buffer.loaded.isEmpty {
                    await MainActor.run { showICloudHint = true }
                }
            }
        }
        .onDisappear {
            processingTask?.cancel()
            iCloudHintTask?.cancel()
        }
        .onChange(of: buffer.loaded.count) { _, count in
            // Dismiss the hint once downloads actually start flowing
            if count > 0 { showICloudHint = false }
        }
    }

    // MARK: - Loading phase

    private var loadingView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.vesperAccent.opacity(0.08))
                        .frame(width: 72, height: 72)
                        .blur(radius: 16)
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Color.vesperAccent)
                }

                Text("Loading photos")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(loadedImages.count == items.count
                     ? "All \(items.count) photos ready"
                     : "Downloading from your library · \(loadedImages.count) of \(items.count)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .animation(.none, value: loadedImages.count)
            }

            VStack(spacing: 6) {
                ProgressView(value: Double(loadedImages.count), total: Double(items.count))
                    .progressViewStyle(.linear)
                    .tint(Color.vesperAccent)

                HStack {
                    Text("If this is slow, your photos may be stored in iCloud")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Text("\(Int(Double(loadedImages.count) / Double(max(items.count, 1)) * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.vesperAccent.opacity(0.7))
                }
            }

            // iCloud slow-load hint — appears after 10 s with 0 photos loaded
            if showICloudHint {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.slash")
                            .font(.subheadline)
                            .foregroundStyle(Color.vesperAccent)
                        Text("Photos are downloading from iCloud")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    Text("Your photos are stored in iCloud and need to be downloaded first. To speed this up:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Open the **Photos** app and scroll through the selected photos — this triggers downloads", systemImage: "1.circle.fill")
                        Label("Or go to **Settings → Photos → Download and Keep Originals** to always keep photos on-device", systemImage: "2.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .labelStyle(.titleAndIcon)
                }
                .padding(16)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.35), value: showICloudHint)
            }

            if !loadedImages.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    // Stable identity: use the UIImage instance, not the array index, so SwiftUI
                    // can diff correctly as photos stream in rather than rebuilding every cell.
                    ForEach(Array(loadedImages.enumerated()), id: \.element) { _, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    ForEach(0..<max(0, items.count - loadedImages.count), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.04))
                            .aspectRatio(1, contentMode: .fill)
                    }
                }
                .frame(maxHeight: 260)
                .clipped()
            } else {
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(0..<min(items.count, 25), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.04))
                            .aspectRatio(1, contentMode: .fill)
                    }
                }
                .frame(maxHeight: 260)
                .clipped()
            }

            // Cancel button — only during the iCloud download phase
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                processingTask?.cancel()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.vesperAccent.opacity(0.5))
                Text("Photos are never uploaded — everything stays on your device")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Analyzing phase

    private var analyzingView: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Color.vesperAccent.opacity(0.08))
                    .frame(width: 72, height: 72)
                    .blur(radius: 16)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
            }

            VStack(spacing: 8) {
                Text("Ranking your photos")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("AI is scoring sharpness, faces & style")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(spacing: 6) {
                if analysisTotal > 0 {
                    ProgressView(value: Double(analysisCompleted), total: Double(analysisTotal))
                        .progressViewStyle(.linear)
                        .tint(Color.vesperAccent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.vesperAccent)
                }

                HStack {
                    Text(analysisTotal > 0 ? "Analyzing photo \(analysisCompleted) of \(analysisTotal)" : "Starting analysis…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    if analysisTotal > 0 {
                        Text("\(Int(Double(analysisCompleted) / Double(analysisTotal) * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.vesperAccent.opacity(0.7))
                    }
                }
            }

            VStack(spacing: 6) {
                if isReferenceDriven {
                    Text("Matching your reference photos")
                        .font(.caption)
                        .foregroundStyle(Color.vesperAccent.opacity(0.7))
                } else if isPromptMode && !promptText.isEmpty {
                    Text("\"\(promptText)\"")
                        .font(.caption)
                        .foregroundStyle(Color.vesperAccent.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else {
                    Text("\(category.rawValue) · \(aesthetics.map(\.rawValue).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text("\(loadedImages.count) photos · top \(pickCount) picks")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    // MARK: - Work

    private func run() async {
        // Check CLIP model loaded — warn but don't block (scoring still works via Vision fallback)
        if CLIPEmbedder.shared == nil {
            // Non-fatal: log but continue — Vision-only scoring still works
        }

        // Phase 1: load images.
        if let preloaded = preloadedImages, !preloaded.isEmpty {
            // Rerun path: images already fetched from PHPhotoLibrary — skip the download phase.
            await MainActor.run {
                phase = .analyzing
                for (i, img) in preloaded.enumerated() {
                    buffer.append(img, at: i)
                }
            }
        } else {
            // Normal path: download from PhotosPickerItems (may trigger iCloud downloads).
            // Cap concurrent downloads at 20 so iCloud bandwidth isn't split across
            // hundreds of simultaneous requests — this makes the first photos appear
            // within a few seconds even when the whole batch is in iCloud.
            let downloadWindow = 20
            var nextDownload = 0

            await withTaskGroup(of: (Int, UIImage?).self) { group in
                // Seed the initial window
                while nextDownload < min(downloadWindow, items.count) {
                    let idx = nextDownload
                    let item = items[idx]
                    group.addTask {
                        let data = try? await item.loadTransferable(type: Data.self)
                        return (idx, data.flatMap { UIImage(data: $0) })
                    }
                    nextDownload += 1
                }

                for await (i, img) in group {
                    guard !Task.isCancelled else { break }
                    if let img {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            buffer.append(img, at: i)
                        }
                    }
                    // As each download completes, immediately queue the next one
                    if nextDownload < items.count {
                        let idx = nextDownload
                        let item = items[idx]
                        group.addTask {
                            let data = try? await item.loadTransferable(type: Data.self)
                            return (idx, data.flatMap { UIImage(data: $0) })
                        }
                        nextDownload += 1
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }

        // If nothing loaded at all, surface an error instead of showing empty results
        if buffer.ordered.isEmpty {
            currentError = .noPhotosLoaded
            return
        }

        // Phase 2: AI analysis
        phase = .analyzing

        let sorted = buffer.ordered.sorted { $0.index < $1.index }
        let sortedImages = sorted.map { $0.image }
        // Map the loaded order back to assetIdentifiers using original indices
        let sortedIdentifiers: [String] = sorted.map { pair in
            pair.index < assetIdentifiers.count ? assetIdentifiers[pair.index] : ""
        }

        analysisTotal = sortedImages.count
        analysisCompleted = 0

        let processor = BatchProcessor()
        let result = await Task { () -> (topPicks: [PhotoResult], runnerUps: [PhotoResult], deleteCandidates: [PhotoResult], similars: [PhotoResult]) in
            return await processor.processImages(
                images: sortedImages,
                assetIdentifiers: sortedIdentifiers,
                pickCount: pickCount,
                category: category,
                aesthetics: aesthetics,
                tasteProfile: tasteProfile,
                referenceEmbeddings: referenceEmbeddings,
                avgEmbedding: avgEmbedding,
                promptEmbedding: promptEmbedding,
                promptText: promptText,
                isPromptMode: isPromptMode,
                isDatingMode: isDatingMode,
                isReferenceDriven: isReferenceDriven,
                purposeTag: purposeTag,
                datingVibe: datingVibe,
                datingAudience: datingAudience,
                likedEmbeddings: likedEmbeddings,
                neutralEmbeddings: neutralEmbeddings,
                dislikedEmbeddings: dislikedEmbeddings,
                dislikeReasonEmbeddings: dislikeReasonEmbeddings,
                contrastEmbeddings: contrastEmbeddings,
                feedbackHistory: feedbackHistory,
                dislikeReasons: dislikeReasons,
                userFaceEmbeddings: userFaceEmbeddings,
                requireUniquePicks: requireUniquePicks,
                onProgress: { completed, total in
                    analysisCompleted = completed
                    analysisTotal = total
                }
            )
        }.result

        guard !Task.isCancelled else { return }

        switch result {
        case .success(let (topPicks, runnerUps, deleteCandidates, similars)):
            // Surface an error if scoring produced nothing at all
            if topPicks.isEmpty && runnerUps.isEmpty && deleteCandidates.isEmpty {
                currentError = .processingFailed
            } else {
                onComplete(topPicks, runnerUps, deleteCandidates, similars)
            }
        case .failure:
            currentError = .processingFailed
        }
    }
}

#Preview {
    ProcessingView(
        items: [],
        assetIdentifiers: [],
        pickCount: 3,
        category: .vacation,
        aesthetics: [.brightAiry],
        tasteProfile: nil,
        referenceEmbeddings: [],
        avgEmbedding: nil,
        promptEmbedding: nil,
        promptText: "",
        isPromptMode: false,
        isDatingMode: false,
        datingVibe: "",
        datingAudience: "",
        likedEmbeddings: [(embedding: [Float], date: Date)](),
        neutralEmbeddings: [(embedding: [Float], date: Date)](),
        dislikedEmbeddings: [(embedding: [Float], date: Date)](),
        dislikeReasonEmbeddings: [(embedding: [Float], date: Date)](),
        contrastEmbeddings: [(embedding: [Float], date: Date)](),
        feedbackHistory: [],
        dislikeReasons: [],
        purposeTag: "",
        requireUniquePicks: true
    ) { _, _, _, _ in }
}
