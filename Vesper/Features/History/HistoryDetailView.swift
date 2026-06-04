//
//  HistoryDetailView.swift
//  Vesper
//

import SwiftUI
import SwiftData
import Photos

private enum RerunStep { case setup, processing, results }

struct HistoryDetailView: View {
    let batch: BatchHistory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var isRenamingBatch = false
    @State private var renameText = ""

    // Rerun state
    @State private var isLoadingRerun = false
    @State private var showRerunFlow = false
    @State private var rerunStep: RerunStep = .setup
    @State private var rerunImages: [UIImage] = []
    @State private var rerunTopPicks: [PhotoResult] = []
    @State private var rerunRunnerUps: [PhotoResult] = []
    @State private var rerunDeleteCandidates: [PhotoResult] = []
    @State private var rerunSimilars: [PhotoResult] = []
    @State private var noPhotosAlert = false

    // Editable rerun settings — pre-filled from batch, user can change before running
    @State private var rerunPickCount: Int = 5
    @State private var rerunCategory: PhotoCategory = .mugshot
    @State private var rerunAesthetics: [AestheticStyle] = []
    @State private var rerunPurpose: BatchPurpose? = nil

    // For re-computing embeddings fresh (picks up AI learning since original run)
    @Query private var referencePhotos: [ReferencePhoto]
    @Query private var allFeedback: [PhotoFeedback]

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    // MARK: - Embedding helpers (mirror BatchSetupView, filtered to active purpose)

    /// Returns the purpose tag in use — the user's edited choice during rerun, otherwise the stored value.
    private var activePurposeTag: String {
        showRerunFlow ? (rerunPurpose?.rawValue ?? batch.purposeTag) : batch.purposeTag
    }

    private var purposeFilteredFeedback: [PhotoFeedback] {
        let tag = activePurposeTag
        if tag.isEmpty { return Array(allFeedback) }
        let matchingPurposeTags = (tag == BatchPurpose.cleanup.rawValue || tag == "Clean up my camera roll")
            ? [BatchPurpose.cleanup.rawValue, "Clean up my camera roll"]
            : [tag]
        return allFeedback.filter { $0.purposeTag.isEmpty || $0.purposeTag == "quiz" || matchingPurposeTags.contains($0.purposeTag) }
    }

    private var tasteProfile: (brightness: Float, saturation: Float, warmth: Float,
                               avgFaceCount: Float, avgSharpness: Float,
                               avgContrast: Float, avgFaceYaw: Float)? {
        guard !referencePhotos.isEmpty else { return nil }
        let n = Float(referencePhotos.count)
        return (
            referencePhotos.map(\.brightness).reduce(0, +) / n,
            referencePhotos.map(\.saturation).reduce(0, +) / n,
            referencePhotos.map(\.warmth).reduce(0, +)    / n,
            referencePhotos.map { Float($0.faceCount) }.reduce(0, +) / n,
            referencePhotos.map(\.sharpness).reduce(0, +) / n,
            referencePhotos.map(\.contrast).reduce(0, +)  / n,
            referencePhotos.map(\.avgFaceYaw).reduce(0, +) / n
        )
    }

    private var referenceEmbeddings: [[Float]] {
        referencePhotos.map(\.embedding).filter { !$0.isEmpty }
    }

    private var avgEmbedding: [Float]? {
        let embs = referenceEmbeddings
        guard !embs.isEmpty else { return nil }
        let dim = embs[0].count
        let valid = embs.filter { $0.count == dim }
        guard !valid.isEmpty else { return nil }
        var avg = [Float](repeating: 0, count: dim)
        for e in valid { for i in 0..<dim { avg[i] += e[i] } }
        let count = Float(valid.count)
        avg = avg.map { $0 / count }
        let mag = sqrt(avg.map { $0 * $0 }.reduce(0, +))
        return mag > 0 ? avg.map { $0 / mag } : avg
    }

    private var likedEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isPositiveSignal)
            .compactMap { f in f.imageEmbedding.isEmpty ? nil : (f.imageEmbedding, f.createdAt) }
    }
    private var neutralEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isNeutralSignal)
            .compactMap { f in f.imageEmbedding.isEmpty ? nil : (f.imageEmbedding, f.createdAt) }
    }
    private var lowRatedEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isNegativeSignal)
            .compactMap { f in f.imageEmbedding.isEmpty ? nil : (f.imageEmbedding, f.createdAt) }
    }
    private var lowRatingReasonEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isNegativeSignal)
            .compactMap { f in f.reasonEmbedding.isEmpty ? nil : (f.reasonEmbedding, f.createdAt) }
    }
    private var contrastEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isPositiveSignal)
            .compactMap { f in f.contrastEmbedding.isEmpty ? nil : (f.contrastEmbedding, f.createdAt) }
    }
    private var lowRatingReasons: [String] {
        purposeFilteredFeedback.filter { $0.isNegativeSignal && !$0.reason.isEmpty }
            .map(\.reason)
    }
    private var userFaceEmbeddings: [[Float]] {
        ReferencePhotoService.userFaceEmbeddings(from: referencePhotos)
    }

    // Reconstruct prompt embedding from stored batch — not user-editable in rerun
    private var rerunPromptEmbedding: [Float]? {
        if batch.isDatingMode {
            let vibes = batch.aesthetic.components(separatedBy: ", ")
            let embeddings = vibes.compactMap { CLIPTextEmbedder.shared?.embed(prompt: $0) }
            guard !embeddings.isEmpty else { return nil }
            let dim = embeddings[0].count
            var avg = [Float](repeating: 0, count: dim)
            for e in embeddings { for i in 0..<dim { avg[i] += e[i] } }
            let n = Float(embeddings.count)
            avg = avg.map { $0 / n }
            let mag = sqrt(avg.map { $0 * $0 }.reduce(0, +))
            return mag > 0 ? avg.map { $0 / mag } : avg
        }
        if batch.isPromptMode && !batch.promptText.isEmpty {
            return CLIPTextEmbedder.shared?.embedWithTemplates(prompt: batch.promptText)
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Metadata card
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: batch.isPromptMode ? "sparkles" : "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(Color.vesperAccent)
                            .frame(width: 44, height: 44)
                            .background(Color.vesperAccent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            if isRenamingBatch {
                                TextField("Batch name", text: $renameText)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .tint(Color.vesperAccent)
                                    .onSubmit { commitRename() }
                            } else {
                                HStack(spacing: 6) {
                                    Text(batch.label)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    Button {
                                        renameText = batch.customName.isEmpty ? batch.label : batch.customName
                                        isRenamingBatch = true
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                            }
                            Text(batch.createdAt.formatted(date: .long, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    Divider().overlay(Color.vesperBorder)

                    HStack(spacing: 0) {
                        statCell(value: "\(batch.pickCount)", label: "Top picks")
                        Divider().frame(height: 32).overlay(Color.vesperBorder)
                        statCell(value: "\(batch.totalPhotos)", label: "Photos scanned")
                        if !batch.isPromptMode && !batch.aesthetic.isEmpty {
                            Divider().frame(height: 32).overlay(Color.vesperBorder)
                            statCell(value: batch.aesthetic, label: "Aesthetic")
                        }
                    }
                }
                .padding(18)
                .vesperCard(cornerRadius: 16)

                // Top picks thumbnails
                if !batch.thumbnails.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Top Picks from this batch")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(Array(batch.thumbnails.enumerated()), id: \.offset) { i, img in
                                ZStack(alignment: .topLeading) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                        .aspectRatio(3/4, contentMode: .fill)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text("#\(i + 1)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(i == 0 ? LinearGradient.vesperGold : LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                                        .clipShape(Capsule())
                                        .padding(8)
                                }
                            }
                        }
                    }
                }

                // Rerun button — only shown when asset identifiers were saved
                if !batch.storedAssetIdentifiers.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task { await startRerun() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingRerun {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(Color.vesperAccent)
                                    .scaleEffect(0.8)
                                Text("Loading photos…")
                            } else {
                                Image(systemName: "slider.horizontal.3")
                                Text("Edit & Rerun")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isLoadingRerun ? .white.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.vesperAccent.opacity(isLoadingRerun ? 0.08 : 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.vesperAccent.opacity(0.3), lineWidth: 1))
                    }
                    .disabled(isLoadingRerun)

                    Text("Adjust settings and rerun these photos with your latest AI feedback applied.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                // Delete button
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Delete from history")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.15), lineWidth: 1))
                }
                .confirmationDialog("Delete this batch from history?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        modelContext.delete(batch)
                        try? modelContext.save()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .vesperBackground()
        .navigationTitle("Batch Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if isRenamingBatch {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitRename() }
                        .foregroundStyle(Color.vesperAccent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isRenamingBatch = false }
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .alert("Photos Unavailable", isPresented: $noPhotosAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The photos from this batch couldn't be loaded. They may have been deleted from your library.")
        }
        .fullScreenCover(isPresented: $showRerunFlow) {
            rerunFlowView
        }
    }

    // MARK: - Rerun flow (fullScreenCover)

    @ViewBuilder
    private var rerunFlowView: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()
            switch rerunStep {
            case .setup:
                rerunSetupView
            case .processing:
                ProcessingView(
                    items: [],
                    assetIdentifiers: batch.storedAssetIdentifiers,
                    pickCount: rerunPickCount,
                    category: rerunCategory,
                    aesthetics: rerunAesthetics,
                    tasteProfile: tasteProfile,
                    referenceEmbeddings: referenceEmbeddings,
                    avgEmbedding: avgEmbedding,
                    promptEmbedding: rerunPromptEmbedding,
                    promptText: batch.isDatingMode ? "" : batch.promptText,
                    isPromptMode: batch.isPromptMode,
                    isDatingMode: batch.isDatingMode,
                    isReferenceDriven: false,
                    datingVibe: batch.isDatingMode ? batch.aesthetic : "",
                    datingAudience: batch.isDatingMode ? batch.promptText : "",
                    likedEmbeddings: likedEmbeddings,
                    neutralEmbeddings: neutralEmbeddings,
                    lowRatedEmbeddings: lowRatedEmbeddings,
                    lowRatingReasonEmbeddings: lowRatingReasonEmbeddings,
                    contrastEmbeddings: contrastEmbeddings,
                    feedbackHistory: Array(purposeFilteredFeedback),
                    lowRatingReasons: lowRatingReasons,
                    purposeTag: activePurposeTag,
                    userFaceEmbeddings: userFaceEmbeddings,
                    requireUniquePicks: true,
                    onComplete: { picks, runners, deletes, sims in
                        rerunTopPicks = picks
                        rerunRunnerUps = runners
                        rerunDeleteCandidates = deletes
                        rerunSimilars = sims
                        // Update the existing batch entry in place
                        batch.pickCount = rerunPickCount
                        if !batch.isDatingMode && !batch.isPromptMode {
                            batch.category  = rerunCategory.rawValue
                            batch.aesthetic = rerunAesthetics.map(\.rawValue).joined(separator: ", ")
                        }
                        if let p = rerunPurpose { batch.purposeTag = p.rawValue }
                        func thumb(_ img: UIImage) -> Data? {
                            let side: CGFloat = 150
                            let s = side / max(img.size.width, img.size.height)
                            let sz = CGSize(width: img.size.width * s, height: img.size.height * s)
                            return UIGraphicsImageRenderer(size: sz)
                                .image { _ in img.draw(in: CGRect(origin: .zero, size: sz)) }
                                .jpegData(compressionQuality: 0.6)
                        }
                        let tops = picks.prefix(4).map(\.image)
                        batch.thumbnail0 = tops.count > 0 ? thumb(tops[0]) : nil
                        batch.thumbnail1 = tops.count > 1 ? thumb(tops[1]) : nil
                        batch.thumbnail2 = tops.count > 2 ? thumb(tops[2]) : nil
                        batch.thumbnail3 = tops.count > 3 ? thumb(tops[3]) : nil
                        try? modelContext.save()
                        withAnimation(.easeInOut) { rerunStep = .results }
                    },
                    preloadedImages: rerunImages
                )
            case .results:
                ResultsView(
                    topPicks: rerunTopPicks,
                    runnerUps: rerunRunnerUps,
                    deleteCandidates: rerunDeleteCandidates,
                    similars: rerunSimilars,
                    isDatingMode: batch.isDatingMode,
                    purposeTag: activePurposeTag,
                    onRerun: nil
                )
            }
        }
        .animation(.easeInOut, value: rerunStep)
    }

    // MARK: - Rerun setup view

    @ViewBuilder
    private var rerunSetupView: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { showRerunFlow = false }
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("Edit & Rerun")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Text("Cancel").opacity(0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Batch info
                    HStack(spacing: 10) {
                        Image(systemName: "photo.stack").foregroundStyle(Color.vesperAccent)
                        Text("\(rerunImages.count) photos loaded")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text("Rerunning with latest AI")
                            .font(.caption).foregroundStyle(Color.vesperAccent)
                    }
                    .padding(14)
                    .vesperCard(cornerRadius: 14)

                    // Pick count
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TOP PICKS").font(.caption.bold()).foregroundStyle(.white.opacity(0.4))
                        HStack {
                            Text("Select \(rerunPickCount) photo\(rerunPickCount == 1 ? "" : "s")")
                                .font(.headline).foregroundStyle(.white)
                            Spacer()
                            Stepper("", value: $rerunPickCount, in: 1...min(30, rerunImages.count))
                                .labelsHidden()
                        }
                        .padding(16)
                        .vesperCard(cornerRadius: 14)
                    }

                    // Purpose picker (not editable for dating/outfit — their setup is fixed)
                    if !batch.isDatingMode && !batch.purposeTag.lowercased().contains("outfit") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PURPOSE").font(.caption.bold()).foregroundStyle(.white.opacity(0.4))
                            VStack(spacing: 8) {
                                ForEach(BatchPurpose.allCases, id: \.self) { purpose in
                                    Button {
                                        rerunPurpose = purpose
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text(purpose.emoji).font(.title3)
                                            Text(purpose.rawValue)
                                                .font(.subheadline).foregroundStyle(.white)
                                            Spacer()
                                            if rerunPurpose == purpose {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(Color.vesperAccent)
                                            }
                                        }
                                        .padding(14)
                                        .background(rerunPurpose == purpose
                                            ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(rerunPurpose == purpose
                                                ? Color.vesperAccent.opacity(0.4) : Color.vesperBorder,
                                                lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }

                    // Category + aesthetics (only for standard mode, not dating/outfit/prompt)
                    if !batch.isDatingMode && !batch.isPromptMode
                       && !batch.purposeTag.lowercased().contains("outfit") {

                        VStack(alignment: .leading, spacing: 10) {
                            Text("CATEGORY").font(.caption.bold()).foregroundStyle(.white.opacity(0.4))
                            VStack(spacing: 8) {
                                ForEach(PhotoCategory.allCases, id: \.self) { cat in
                                    Button { rerunCategory = cat } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: cat.icon)
                                                .font(.body)
                                                .foregroundStyle(rerunCategory == cat
                                                    ? Color.vesperAccent : .white.opacity(0.6))
                                                .frame(width: 26)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(cat.displayName)
                                                    .font(.subheadline).foregroundStyle(.white)
                                                Text(cat.description)
                                                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                                            }
                                            Spacer()
                                            if rerunCategory == cat {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(Color.vesperAccent)
                                            }
                                        }
                                        .padding(14)
                                        .background(rerunCategory == cat
                                            ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(rerunCategory == cat
                                                ? Color.vesperAccent.opacity(0.4) : Color.vesperBorder,
                                                lineWidth: 1))
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("AESTHETIC").font(.caption.bold()).foregroundStyle(.white.opacity(0.4))
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(AestheticStyle.allCases, id: \.self) { style in
                                    let on = rerunAesthetics.contains(style)
                                    Button {
                                        if on { rerunAesthetics.removeAll { $0 == style } }
                                        else  { rerunAesthetics.append(style) }
                                    } label: {
                                        VStack(spacing: 6) {
                                            Image(systemName: style.icon)
                                                .font(.title2)
                                                .foregroundStyle(on ? Color.vesperAccent : .white.opacity(0.6))
                                            Text(style.rawValue)
                                                .font(.caption.bold()).foregroundStyle(.white)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(on ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(on ? Color.vesperAccent.opacity(0.4) : Color.vesperBorder,
                                                lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }

                    // Run button
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        rerunStep = .processing
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Run with Updated AI")
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(LinearGradient.vesperGold)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Text("Your latest feedback and reference photos will be applied — results may differ from the original run.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Image fetching

    private func startRerun() async {
        guard !batch.storedAssetIdentifiers.isEmpty else { return }
        isLoadingRerun = true
        defer { isLoadingRerun = false }

        let identifiers = batch.storedAssetIdentifiers
        let images = await fetchImages(for: identifiers)

        if images.isEmpty {
            noPhotosAlert = true
            return
        }

        rerunImages = images

        // Pre-fill editable settings from stored batch so user sees current values
        rerunPickCount = batch.pickCount
        rerunCategory = PhotoCategory(rawValue: batch.category) ?? .mugshot
        rerunAesthetics = batch.aesthetic.components(separatedBy: ", ")
            .compactMap { AestheticStyle(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        rerunPurpose = BatchPurpose.allCases.first { $0.rawValue == batch.purposeTag }

        rerunStep = .setup
        showRerunFlow = true
    }

    private func fetchImages(for identifiers: [String]) async -> [UIImage] {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetchResult.count > 0 else { return [] }

        return await withTaskGroup(of: (Int, UIImage?).self) { group in
            for i in 0..<fetchResult.count {
                let asset = fetchResult.object(at: i)
                let index = i
                group.addTask {
                    await withCheckedContinuation { cont in
                        let opts = PHImageRequestOptions()
                        opts.isSynchronous = false
                        opts.isNetworkAccessAllowed = true
                        opts.deliveryMode = .highQualityFormat
                        opts.resizeMode = .none

                        var resumed = false
                        PHImageManager.default().requestImage(
                            for: asset,
                            targetSize: CGSize(width: 2048, height: 2048),
                            contentMode: .aspectFit,
                            options: opts
                        ) { img, info in
                            guard !resumed else { return }
                            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                            let hasError = info?[PHImageErrorKey] != nil
                            if !isDegraded || isCancelled || hasError {
                                resumed = true
                                cont.resume(returning: (index, img))
                            }
                        }
                    }
                }
            }

            var pairs: [(Int, UIImage)] = []
            for await (idx, img) in group {
                if let img { pairs.append((idx, img)) }
            }
            return pairs.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Helpers

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        batch.customName = trimmed
        try? modelContext.save()
        isRenamingBatch = false
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}
