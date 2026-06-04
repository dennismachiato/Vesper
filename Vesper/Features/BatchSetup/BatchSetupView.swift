//
//  BatchSetupView.swift
//  Vesper
//
//  Created by Dennis Mach on 4/1/26.
//

import SwiftUI
import PhotosUI
import SwiftData
import OSLog

private let batchSetupLogger = Logger(subsystem: "Vesper", category: "BatchSetup")

enum BatchPurpose: String, CaseIterable {
    case cleanup    = "Pick best from a batch"
    case dating     = "Dating profile"
    case social     = "Social media post"
    case professional = "Professional / headshots"
    case outfit     = "Outfit check"
    case general    = "Just pick my best shots"

    var emoji: String {
        switch self {
        case .cleanup:      return "🗂️"
        case .dating:       return "💘"
        case .social:       return "📱"
        case .professional: return "💼"
        case .outfit:       return "👗"
        case .general:      return "✨"
        }
    }

    var tagline: String {
        switch self {
        case .cleanup:      return "Choose winners from similar shots"
        case .dating:       return "Hinge, Tinder, Bumble — put your best face forward"
        case .social:       return "Instagram, TikTok, or whatever you post on"
        case .professional: return "LinkedIn, headshots, or work profiles"
        case .outfit:       return "Best outfit shot + color & contrast feedback"
        case .general:      return "Rank and explore your photos"
        }
    }
}

enum BatchStep {
    case photos, purpose, modeSelect, category, aesthetic, prompt, datingVibe, datingAudience, outfitSetup, pickCount, processing, results
}

struct BatchSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var topPicks: [PhotoResult] = []
    @State private var runnerUps: [PhotoResult] = []
    @State private var deleteCandidates: [PhotoResult] = []
    @State private var similars: [PhotoResult] = []
    @State private var step: BatchStep = .photos
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var assetIdentifiers: [String] = []   // PHAsset localIdentifier per selected item
    @State private var selectedPurpose: BatchPurpose?
    @State private var selectedCategory: PhotoCategory?
    @State private var selectedAesthetics: [AestheticStyle] = []
    @State private var pickCount: Int = 3
    @State private var requireUniquePicks: Bool = true
    @State private var promptText: String = ""
    @State private var promptEmbedding: [Float]? = nil
    @State private var usePromptMode: Bool = false
    @State private var useDatingMode: Bool = false
    /// When true, scoring leans on the user's reference photos as the primary
    /// taste signal — no prompt, no aesthetic picker. Hard-gated on
    /// `!referencePhotos.isEmpty` everywhere it's offered.
    @State private var useReferenceDrivenMode: Bool = false
    @State private var showRefRequiredAlert: Bool = false
    @State private var selectedVibes: [DatingVibe] = []
    @State private var selectedAudience: DatingAudience = .everyone
    @State private var outfitOccasion: OutfitOccasion = .casual
    @State private var outfitFocus: OutfitFocus = .overall
    @Query private var referencePhotos: [ReferencePhoto]
    @Query private var feedbackHistory: [PhotoFeedback]

    private var tasteProfile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                               avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)? {
        guard !referencePhotos.isEmpty else { return nil }
        let count = Float(referencePhotos.count)
        let b  = referencePhotos.map(\.brightness).reduce(0, +) / count
        let s  = referencePhotos.map(\.saturation).reduce(0, +) / count
        let w  = referencePhotos.map(\.warmth).reduce(0, +) / count
        let f  = referencePhotos.map { Float($0.faceCount) }.reduce(0, +) / count
        let sh = referencePhotos.map(\.sharpness).reduce(0, +) / count
        let co = referencePhotos.map(\.contrast).reduce(0, +) / count
        let yw = referencePhotos.map(\.avgFaceYaw).reduce(0, +) / count
        return (b, s, w, f, sh, co, yw)
    }

    /// Feedback filtered to entries that match the current purpose.
    /// Empty tags and style-quiz entries are global baseline taste signals.
    /// Dating feedback doesn't influence Instagram picks and vice-versa.
    private var purposeFilteredFeedback: [PhotoFeedback] {
        guard let purpose = selectedPurpose else { return Array(feedbackHistory) }
        let matchingPurposeTags = purpose == .cleanup
            ? [purpose.rawValue, "Clean up my camera roll"]
            : [purpose.rawValue]
        return feedbackHistory.filter { f in
            f.purposeTag.isEmpty || f.purposeTag == "quiz" || matchingPurposeTags.contains(f.purposeTag)
        }
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

    /// Embeddings of photos seen just before high-rated photos — the implicit "runner-up" that was rejected.
    /// Used as a mild contrastive penalty: photos similar to these get a small score reduction.
    private var contrastEmbeddings: [(embedding: [Float], date: Date)] {
        purposeFilteredFeedback.filter(\.isPositiveSignal)
            .compactMap { f in f.contrastEmbedding.isEmpty ? nil : (f.contrastEmbedding, f.createdAt) }
    }

    /// Raw low-rating reason strings — passed to BatchProcessor for dimension hint extraction.
    private var lowRatingReasons: [String] {
        purposeFilteredFeedback.filter { $0.isNegativeSignal && !$0.reason.isEmpty }
            .map(\.reason)
    }

    // Individual per-reference embeddings passed directly to ReferenceScorer
    private var referenceEmbeddings: [[Float]] {
        referencePhotos.map(\.embedding).filter { !$0.isEmpty }
    }

    /// The user's face signature(s), identified as the face recurring across reference photos —
    /// used to focus scoring on the user in group/multi-person batch photos. Falls back to dominant
    /// face crops when recurrence can't be established (few references or no recurring face).
    private var userFaceEmbeddings: [[Float]] {
        ReferencePhotoService.userFaceEmbeddings(from: referencePhotos)
    }

    private var avgEmbedding: [Float]? {
        let embeddings = referenceEmbeddings
        guard !embeddings.isEmpty else { return nil }
        let dim = embeddings[0].count
        let validEmbeddings = embeddings.filter { $0.count == dim }
        guard !validEmbeddings.isEmpty else { return nil }
        var avg = [Float](repeating: 0, count: dim)
        for emb in validEmbeddings { for i in 0..<dim { avg[i] += emb[i] } }
        let count = Float(validEmbeddings.count)
        avg = avg.map { $0 / count }
        let magnitude = sqrt(avg.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return avg }
        return avg.map { $0 / magnitude }
    }

    // Returns the step to go back to, or nil if there is no back
    private func previousStep(from step: BatchStep) -> BatchStep? {
        switch step {
        case .photos:         return nil
        case .purpose:        return .photos
        case .modeSelect:     return .purpose
        case .category:       return .modeSelect
        case .aesthetic:      return .category
        case .prompt:         return .modeSelect
        case .datingVibe:     return .purpose
        case .datingAudience: return .datingVibe
        case .outfitSetup:    return .purpose
        case .pickCount:
            if useDatingMode             { return .datingAudience }
            if selectedPurpose == .outfit { return .outfitSetup }
            if useReferenceDrivenMode    { return .modeSelect }
            if usePromptMode             { return .prompt }
            return .aesthetic
        case .processing:     return nil
        case .results:        return nil
        }
    }

    /// Returns (stepsCompleted, totalSteps) for the progress dot indicator.
    /// nil = hide the indicator (photos picker, processing, results).
    private var stepProgress: (Int, Int)? {
        switch step {
        case .photos, .processing, .results: return nil
        case .purpose:
            return (0, 4)
        case .modeSelect, .datingVibe, .outfitSetup:
            return (1, 4)
        case .datingAudience, .category, .prompt:
            return (2, 4)
        case .aesthetic:
            return (2, 4)
        case .pickCount:
            return (3, 4)
        }
    }

    private var useOutfitMode: Bool { selectedPurpose == .outfit }

    private var effectivePromptText: String {
        if useDatingMode  { return selectedVibes.first?.clipPrompt ?? "" }
        if useOutfitMode  { return outfitFocus.clipPrompt(occasion: outfitOccasion) }
        return promptText
    }

    private var effectivePromptEmbedding: [Float]? {
        if useDatingMode {
            let embeddings = selectedVibes.compactMap { CLIPTextEmbedder.shared?.embed(prompt: $0.clipPrompt) }
            guard !embeddings.isEmpty else { return nil }
            let dim = embeddings[0].count
            var avg = [Float](repeating: 0, count: dim)
            for emb in embeddings { for i in 0..<dim { avg[i] += emb[i] } }
            let count = Float(embeddings.count)
            avg = avg.map { $0 / count }
            let mag = sqrt(avg.map { $0 * $0 }.reduce(0, +))
            guard mag > 0 else { return avg }
            return avg.map { $0 / mag }
        }
        if useOutfitMode  { return CLIPTextEmbedder.shared?.embed(prompt: effectivePromptText) }
        return promptEmbedding
    }

    private var effectiveIsPrompt: Bool {
        useDatingMode || useOutfitMode || usePromptMode
    }

    // Extracted to avoid let-bindings inside a ViewBuilder switch case
    @ViewBuilder private var processingView: some View {
        ProcessingView(
            items: selectedItems,
            assetIdentifiers: assetIdentifiers,
            pickCount: pickCount,
            category: useDatingMode ? .mugshot : (useOutfitMode ? .mugshot : (selectedCategory ?? .vacation)),
            aesthetics: (useDatingMode || useOutfitMode) ? [.candidRaw] : (selectedAesthetics.isEmpty ? [.candidRaw] : selectedAesthetics),
            tasteProfile: tasteProfile,
            referenceEmbeddings: referenceEmbeddings,
            avgEmbedding: avgEmbedding,
            promptEmbedding: effectivePromptEmbedding,
            promptText: effectivePromptText,
            isPromptMode: effectiveIsPrompt,
            isDatingMode: useDatingMode,
            isReferenceDriven: useReferenceDrivenMode,
            datingVibe: selectedVibes.map(\.rawValue).joined(separator: ", "),
            datingAudience: selectedAudience.rawValue,
            likedEmbeddings: likedEmbeddings,
            neutralEmbeddings: neutralEmbeddings,
            lowRatedEmbeddings: lowRatedEmbeddings,
            lowRatingReasonEmbeddings: lowRatingReasonEmbeddings,
            contrastEmbeddings: contrastEmbeddings,
            feedbackHistory: Array(purposeFilteredFeedback),
            lowRatingReasons: lowRatingReasons,
            purposeTag: selectedPurpose?.rawValue ?? "",
            userFaceEmbeddings: userFaceEmbeddings,
            requireUniquePicks: requireUniquePicks
        ) { picks, runners, deletes, sims in
            topPicks = picks
            runnerUps = runners
            deleteCandidates = deletes
            similars = sims
            let entry = BatchHistory(
                category: useDatingMode ? "Dating" : (selectedCategory?.rawValue ?? ""),
                aesthetic: useDatingMode ? selectedVibes.map(\.rawValue).joined(separator: ", ") : selectedAesthetics.map(\.rawValue).joined(separator: ", "),
                promptText: useDatingMode ? selectedAudience.rawValue : promptText,
                isPromptMode: usePromptMode || useDatingMode,
                pickCount: pickCount,
                totalPhotos: selectedItems.count,
                thumbnails: picks.prefix(4).map { $0.image },
                assetIdentifiers: assetIdentifiers,
                purposeTag: selectedPurpose?.rawValue ?? ""
            )
            modelContext.insert(entry)
            do {
                try modelContext.save()
            } catch {
                batchSetupLogger.error("Save batch history failed: \(error.localizedDescription, privacy: .private)")
            }
            step = .results
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch step {
                case .photos:
                    photoSelectionView

                case .purpose:
                    purposeSelectionView

                case .modeSelect:
                    modeSelectionView

                case .category:
                    CategorySelectionView(selectedCategory: $selectedCategory) {
                        step = .aesthetic
                    }

                case .aesthetic:
                    AestheticSelectionView(selectedAesthetics: $selectedAesthetics) {
                        step = .pickCount
                    }

                case .prompt:
                    PromptInputView(promptText: $promptText) {
                        if !promptText.trimmingCharacters(in: .whitespaces).isEmpty {
                            promptEmbedding = CLIPTextEmbedder.shared?.embedWithTemplates(prompt: promptText)
                        }
                        step = .pickCount
                    }

                case .datingVibe:
                    DatingVibeSelectionView(selectedVibes: $selectedVibes) {
                        step = .datingAudience
                    }

                case .datingAudience:
                    DatingAudienceView(selectedAudience: $selectedAudience) {
                        step = .pickCount
                    }

                case .outfitSetup:
                    OutfitSetupView(selectedOccasion: $outfitOccasion, selectedFocus: $outfitFocus) {
                        step = .pickCount
                    }

                case .pickCount:
                    PickCountView(pickCount: $pickCount, requireUniquePicks: $requireUniquePicks, totalPhotos: selectedItems.count) {
                        step = .processing
                    }

                case .processing:
                    processingView

                case .results:
                    ResultsView(
                        topPicks: topPicks,
                        runnerUps: runnerUps,
                        deleteCandidates: deleteCandidates,
                        similars: similars,
                        isDatingMode: useDatingMode,
                        purposeTag: selectedPurpose?.rawValue ?? "",
                        onRerun: {
                            withAnimation(.easeInOut) { step = .purpose }
                        }
                    )
                }
            }
            .animation(.easeInOut, value: step)

            // Back button — steps with a previous step animate back; photos step dismisses
            if let prev = previousStep(from: step) {
                Button {
                    withAnimation(.easeInOut) { step = prev }
                } label: {
                    backButtonLabel
                }
                .padding(.top, 56)
                .padding(.leading, 20)
            } else if step == .photos {
                Button { dismiss() } label: {
                    backButtonLabel
                }
                .padding(.top, 56)
                .padding(.leading, 20)
            }

            // Step progress dots — top-right, hidden on processing/results
            if let (current, total) = stepProgress {
                HStack(spacing: 5) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(i < current ? Color.vesperAccent : Color.white.opacity(0.2))
                            .frame(width: i < current ? 14 : 6, height: 6)
                            .animation(.spring(response: 0.3), value: current)
                    }
                }
                .padding(.top, 62)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private var backButtonLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
            Text("Back")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08))
        .clipShape(Capsule())
    }

    var photoSelectionView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Select Photos")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Choose your batch from your camera roll")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 100)

            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 300,
                matching: .images
            ) {
                VStack(spacing: 14) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.vesperAccent)
                    Text("Choose from Camera Roll")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Select up to 300 photos")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .padding(44)
                .vesperCard(cornerRadius: 20)
                .padding(.horizontal, 28)
            }
            .onChange(of: selectedItems) { _, items in
                // itemIdentifier == PHAsset.localIdentifier — used later for delete-from-library
                assetIdentifiers = items.map { $0.itemIdentifier ?? "" }
            }

            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) photos selected")
                    .font(.subheadline)
                    .foregroundStyle(Color.vesperAccent)

                Button {
                    step = .purpose
                } label: {
                    Text("Continue")
                        .vesperPrimaryButton()
                }
                .padding(.horizontal, 28)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.vesperAccent.opacity(0.5))
                Text("All analysis happens on your device — photos are never uploaded")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
    }

    var purposeSelectionView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("What's the goal?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Helps us pick and explain your photos better")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 100)
            .padding(.horizontal, 28)

            VStack(spacing: 10) {
                ForEach(BatchPurpose.allCases, id: \.self) { purpose in
                    Button {
                        selectedPurpose = purpose
                        if purpose == .dating {
                            useDatingMode = true
                            usePromptMode = false
                            selectedVibes = []
                            withAnimation(.easeInOut) { step = .datingVibe }
                        } else if purpose == .outfit {
                            useDatingMode = false
                            usePromptMode = false
                            withAnimation(.easeInOut) { step = .outfitSetup }
                        } else {
                            useDatingMode = false
                            if purpose == .professional {
                                selectedCategory = .mugshot
                            }
                            withAnimation(.easeInOut) { step = .modeSelect }
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Text(purpose.emoji)
                                .font(.title2)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(purpose.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(purpose.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(16)
                        .vesperCard(cornerRadius: 14)
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
    }

    var modeSelectionView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("How do you want to filter?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Pick a mode for this batch")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 100)

            VStack(spacing: 12) {
                // Category & Aesthetic
                Button {
                    usePromptMode = false
                    useReferenceDrivenMode = false
                    step = .category
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Category & Aesthetic")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Choose a style and vibe")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(18)
                    .vesperCard(cornerRadius: 14)
                }
                .padding(.horizontal, 24)

                // Skip description — use the user's reference photos as the
                // taste signal. Hard-gated: button is hidden entirely when no
                // references exist (we surface a Profile deeplink instead).
                if !referencePhotos.isEmpty {
                    Button {
                        useReferenceDrivenMode = true
                        usePromptMode = false
                        useDatingMode = false
                        selectedAesthetics = []
                        promptText = ""
                        promptEmbedding = nil
                        step = .pickCount
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(Color.vesperAccent)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Use My References")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Skip the description — pick using your \(referencePhotos.count) reference photo\(referencePhotos.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(18)
                        .vesperCard(cornerRadius: 14)
                    }
                    .padding(.horizontal, 24)

                    referenceReadinessNote
                }

                // Prompt / Describe It
                Button {
                    usePromptMode = true
                    useDatingMode = false
                    useReferenceDrivenMode = false
                    step = .prompt
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(.black)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Describe It")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                            }
                            Text("Type exactly what you're looking for")
                                .font(.caption)
                                .foregroundStyle(.black.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.black.opacity(0.4))
                    }
                    .padding(18)
                    .background(LinearGradient.vesperGold)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)

            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
    }

    private var referenceReadinessNote: some View {
        let needsMore = referencePhotos.count < 5
        let groupRefs = referencePhotos.filter { $0.faceCount > 1 }.count
        let hasManyGroupRefs = groupRefs >= max(2, referencePhotos.count / 2)
        let tint: Color = hasManyGroupRefs ? .orange : Color.vesperAccent
        let title = needsMore ? "Reference matching is still warming up" : "References are ready to guide picks"
        let body = hasManyGroupRefs
            ? "A few clear solo references will help Vesper recognize you in group shots."
            : (needsMore
               ? "For stronger style and face matching, add 5-10 clear favorites in Profile."
               : "Best results come from references where you are clearly visible.")

        return HStack(spacing: 10) {
            Image(systemName: hasManyGroupRefs ? "person.2.badge.gearshape.fill" : "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.78))
                Text(body)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, 24)
    }
}

#Preview {
    BatchSetupView()
}
