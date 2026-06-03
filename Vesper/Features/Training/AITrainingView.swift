//
//  AITrainingView.swift
//  Vesper
//

import SwiftUI
import PhotosUI
import SwiftData
import OSLog

private let aiTrainingLogger = Logger(subsystem: "Vesper", category: "AITraining")

private struct TrainingPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum TrainingMode: String, CaseIterable {
    case rate = "Rate"
    case compare = "Compare"
}

struct AITrainingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [TrainingPhoto] = []
    @State private var currentIndex = 0
    @State private var feedbackSaved: [Int: GalleryView.FeedbackState] = [:]
    @State private var feedbackRecords: [Int: PhotoFeedback] = [:]
    @State private var lastSavedIndices: [Int] = []
    @State private var trainingMode: TrainingMode = .rate
    @State private var isLoading = false
    @State private var loadingProgress: Double = 0
    @State private var isSaving = false
    @State private var showDislikeSheet = false
    @State private var saveError: String?

    private var currentPhoto: TrainingPhoto? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    private var ratedCount: Int { feedbackSaved.count }
    private var isComplete: Bool { !photos.isEmpty && ratedCount == photos.count && !isSaving }
    private var currentPair: (left: Int, right: Int)? {
        guard photos.count >= 2 else { return nil }
        let unrated = photos.indices.filter { feedbackSaved[$0] == nil }
        guard unrated.count >= 2 else { return nil }
        let left = unrated.contains(currentIndex) ? currentIndex : unrated[0]
        let right = unrated.first(where: { $0 != left }) ?? unrated[1]
        return (left, right)
    }

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            if photos.isEmpty {
                setupView
            } else if isComplete {
                completeView
            } else if trainingMode == .compare, currentPair != nil {
                comparisonView
            } else {
                ratingView
            }
        }
        .navigationTitle("Test the AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showDislikeSheet) {
            DislikeReasonSheet { reason in
                showDislikeSheet = false
                saveCurrentFeedback(liked: false, isNeutral: false, reason: reason)
            }
        }
        .alert("Feedback Not Saved", isPresented: .init(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var setupView: some View {
        VStack(spacing: 26) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.vesperAccent.opacity(0.08))
                    .frame(width: 96, height: 96)
                    .blur(radius: 20)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
            }

            VStack(spacing: 10) {
                Text("Teach Vesper Your Taste")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Pick a recent batch of similar photos, then mark each one as Like, OK, or Dislike. This trains your local preference profile without uploading photos.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView(value: loadingProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(Color.vesperAccent)
                    Text("Loading \(Int(loadingProgress * Double(max(pickerItems.count, 1)))) of \(pickerItems.count) photos")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 36)
            } else {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 50, matching: .images) {
                    Text("Choose Similar Photos")
                        .vesperPrimaryButton()
                }
                .padding(.horizontal, 28)
                .onChange(of: pickerItems) { _, items in
                    Task { await loadPhotos(from: items) }
                }

                Text("Best with 10-50 shots from the same moment, outfit, or shoot.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.38))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }

            Spacer()
        }
    }

    private var ratingView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rate this batch")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("\(ratedCount) of \(photos.count) saved")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text("\(currentIndex + 1) / \(photos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.vesperAccent.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.vesperAccent.opacity(0.10))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            ProgressView(value: Double(ratedCount), total: Double(max(photos.count, 1)))
                .progressViewStyle(.linear)
                .tint(Color.vesperAccent)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            trainingModePicker
                .padding(.horizontal, 20)
                .padding(.top, 12)

            Spacer(minLength: 18)

            if let currentPhoto {
                Image(uiImage: currentPhoto.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 16)
            }

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                trainingButton(icon: "hand.thumbsup.fill", label: "Like", tint: .green) {
                    saveCurrentFeedback(liked: true, isNeutral: false, reason: "")
                }
                trainingButton(icon: "hand.raised.fill", label: "OK", tint: .orange) {
                    saveCurrentFeedback(liked: false, isNeutral: true, reason: "")
                }
                trainingButton(icon: "hand.thumbsdown.fill", label: "Dislike", tint: .red) {
                    showDislikeSheet = true
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Button {
                moveToNextUnratedPhoto(startingAfter: currentIndex)
            } label: {
                Text("Skip this photo")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .disabled(isSaving)
            .padding(.horizontal, 20)

            if !lastSavedIndices.isEmpty {
                Button {
                    undoTrainingFeedback(at: lastSavedIndices)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo last rating")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .disabled(isSaving)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            Spacer().frame(height: 22)
        }
    }

    private var trainingModePicker: some View {
        Picker("Training Mode", selection: $trainingMode) {
            ForEach(TrainingMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isSaving)
    }

    private var comparisonView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare two photos")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("\(ratedCount) of \(photos.count) saved")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            ProgressView(value: Double(ratedCount), total: Double(max(photos.count, 1)))
                .progressViewStyle(.linear)
                .tint(Color.vesperAccent)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            trainingModePicker
                .padding(.horizontal, 20)
                .padding(.top, 12)

            Spacer(minLength: 16)

            if let pair = currentPair {
                HStack(spacing: 10) {
                    comparisonPhoto(index: pair.left, label: "A")
                    comparisonPhoto(index: pair.right, label: "B")
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 18)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        comparisonButton(title: "Prefer A", icon: "a.circle.fill", tint: .green) {
                            savePairwisePreference(winnerIndex: pair.left, loserIndex: pair.right)
                        }
                        comparisonButton(title: "Prefer B", icon: "b.circle.fill", tint: .green) {
                            savePairwisePreference(winnerIndex: pair.right, loserIndex: pair.left)
                        }
                    }

                    comparisonButton(title: "Both OK", icon: "hand.raised.fill", tint: .orange) {
                        savePairwiseNeutral(leftIndex: pair.left, rightIndex: pair.right)
                    }

                    Button {
                        moveToNextUnratedPhoto(startingAfter: max(pair.left, pair.right))
                    } label: {
                        Text("Skip this pair")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, 20)
            } else {
                Text("One photo left — switch to Rate to finish.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 24)
            }

            if !lastSavedIndices.isEmpty {
                Button {
                    undoTrainingFeedback(at: lastSavedIndices)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo last comparison")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .disabled(isSaving)
                .padding(.top, 10)
            }

            Spacer().frame(height: 22)
        }
    }

    private var completeView: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.vesperAccent)

            VStack(spacing: 8) {
                Text("Training Saved")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("\(ratedCount) ratings were added to your local preference profile. Future batches can use this signal right away.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }

            VStack(spacing: 12) {
                Button {
                    resetTraining()
                } label: {
                    Text("Train Another Batch")
                        .vesperPrimaryButton()
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .vesperCard(cornerRadius: 14)
                }
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    private func trainingButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(tint)
                } else {
                    Image(systemName: icon)
                }
                Text(label)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(tint.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.20), lineWidth: 1))
        }
        .disabled(isSaving)
    }

    private func comparisonPhoto(index: Int, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: photos[index].image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10), lineWidth: 1))

            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(LinearGradient.vesperGold)
                .clipShape(Capsule())
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func comparisonButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(tint)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(tint.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.20), lineWidth: 1))
        }
        .disabled(isSaving)
    }

    private func loadPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        await MainActor.run {
            isLoading = true
            loadingProgress = 0
            photos = []
            feedbackSaved = [:]
            feedbackRecords = [:]
            lastSavedIndices = []
            trainingMode = .rate
            currentIndex = 0
        }

        var loaded: [TrainingPhoto] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(TrainingPhoto(image: image))
            }
            await MainActor.run {
                loadingProgress = Double(index + 1) / Double(items.count)
            }
        }

        await MainActor.run {
            photos = loaded
            isLoading = false
            pickerItems = []
        }
    }

    private func saveCurrentFeedback(liked: Bool, isNeutral: Bool, reason: String) {
        guard photos.indices.contains(currentIndex), feedbackSaved[currentIndex] == nil else { return }
        let index = currentIndex
        let image = photos[index].image

        feedbackSaved[index] = isNeutral ? .neutral : (liked ? .liked : .disliked)
        isSaving = true

        Task {
            let embedding = await CLIPEmbedder.shared?.embedAsync(image: image) ?? []
            await MainActor.run {
                let feedback = PhotoFeedback(
                    liked: liked,
                    isNeutral: isNeutral,
                    reason: reason,
                    imageEmbedding: embedding,
                    purposeTag: ""
                )
                modelContext.insert(feedback)
                do {
                    try modelContext.save()
                    feedbackRecords[index] = feedback
                    lastSavedIndices = [index]
                    UINotificationFeedbackGenerator().notificationOccurred(liked ? .success : (isNeutral ? .warning : .error))
                    isSaving = false
                    moveToNextUnratedPhoto(startingAfter: index)
                } catch {
                    feedbackSaved[index] = nil
                    isSaving = false
                    saveError = error.localizedDescription
                    aiTrainingLogger.error("Training feedback save failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func savePairwisePreference(winnerIndex: Int, loserIndex: Int) {
        savePairwiseFeedback(
            leftIndex: winnerIndex,
            rightIndex: loserIndex,
            leftState: .liked,
            rightState: .disliked,
            rightReason: "Preferred another photo"
        )
    }

    private func savePairwiseNeutral(leftIndex: Int, rightIndex: Int) {
        savePairwiseFeedback(
            leftIndex: leftIndex,
            rightIndex: rightIndex,
            leftState: .neutral,
            rightState: .neutral
        )
    }

    private func savePairwiseFeedback(
        leftIndex: Int,
        rightIndex: Int,
        leftState: GalleryView.FeedbackState,
        rightState: GalleryView.FeedbackState,
        leftReason: String = "",
        rightReason: String = ""
    ) {
        guard photos.indices.contains(leftIndex),
              photos.indices.contains(rightIndex),
              feedbackSaved[leftIndex] == nil,
              feedbackSaved[rightIndex] == nil,
              !isSaving else { return }

        feedbackSaved[leftIndex] = leftState
        feedbackSaved[rightIndex] = rightState
        isSaving = true

        let leftImage = photos[leftIndex].image
        let rightImage = photos[rightIndex].image

        Task {
            let leftEmbedding = await CLIPEmbedder.shared?.embedAsync(image: leftImage) ?? []
            let rightEmbedding = await CLIPEmbedder.shared?.embedAsync(image: rightImage) ?? []

            await MainActor.run {
                let leftFeedback = PhotoFeedback(
                    liked: leftState == .liked,
                    isNeutral: leftState == .neutral,
                    reason: leftReason,
                    imageEmbedding: leftEmbedding,
                    reasonEmbedding: [],
                    purposeTag: "",
                    contrastEmbedding: rightEmbedding
                )
                let rightFeedback = PhotoFeedback(
                    liked: rightState == .liked,
                    isNeutral: rightState == .neutral,
                    reason: rightReason,
                    imageEmbedding: rightEmbedding,
                    reasonEmbedding: [],
                    purposeTag: "",
                    contrastEmbedding: leftEmbedding
                )

                modelContext.insert(leftFeedback)
                modelContext.insert(rightFeedback)
                do {
                    try modelContext.save()
                    feedbackRecords[leftIndex] = leftFeedback
                    feedbackRecords[rightIndex] = rightFeedback
                    lastSavedIndices = [leftIndex, rightIndex]
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    isSaving = false
                    moveToNextUnratedPhoto(startingAfter: max(leftIndex, rightIndex))
                } catch {
                    modelContext.rollback()
                    feedbackSaved[leftIndex] = nil
                    feedbackSaved[rightIndex] = nil
                    isSaving = false
                    saveError = error.localizedDescription
                    aiTrainingLogger.error("Pairwise training feedback save failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func undoTrainingFeedback(at indices: [Int]) {
        let validIndices = indices.filter { photos.indices.contains($0) && feedbackSaved[$0] != nil }
        guard !validIndices.isEmpty, !isSaving else { return }
        let previousStates = Dictionary(uniqueKeysWithValues: validIndices.map { ($0, feedbackSaved[$0]) })
        let previousRecords = Dictionary(uniqueKeysWithValues: validIndices.compactMap { index in
            feedbackRecords[index].map { (index, $0) }
        })
        for index in validIndices {
            feedbackSaved[index] = nil
            feedbackRecords[index] = nil
        }
        lastSavedIndices = []
        isSaving = true

        do {
            for record in previousRecords.values {
                modelContext.delete(record)
            }
            try modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.easeInOut(duration: 0.2)) {
                currentIndex = validIndices.min() ?? currentIndex
            }
        } catch {
            modelContext.rollback()
            for (index, state) in previousStates {
                feedbackSaved[index] = state
            }
            for (index, record) in previousRecords {
                feedbackRecords[index] = record
            }
            lastSavedIndices = validIndices
            saveError = error.localizedDescription
            aiTrainingLogger.error("Training feedback undo failed: \(error.localizedDescription, privacy: .private)")
        }
        isSaving = false
    }

    private func moveToNextUnratedPhoto(startingAfter index: Int) {
        guard !photos.isEmpty else { return }
        let laterIndices = photos.indices.dropFirst(index + 1)
        let earlierIndices = photos.indices.prefix(index)
        let next = laterIndices.first(where: { feedbackSaved[$0] == nil }) ??
                   earlierIndices.first(where: { feedbackSaved[$0] == nil })
        if let next {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentIndex = next
            }
        }
    }

    private func resetTraining() {
        pickerItems = []
        photos = []
        feedbackSaved = [:]
        feedbackRecords = [:]
        lastSavedIndices = []
        trainingMode = .rate
        currentIndex = 0
        loadingProgress = 0
        isLoading = false
        isSaving = false
    }
}

#Preview {
    NavigationStack {
        AITrainingView()
    }
}
