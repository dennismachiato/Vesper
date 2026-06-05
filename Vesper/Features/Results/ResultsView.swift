//
//  ResultsView.swift
//  Vesper
//
//  Created by Dennis Mach on 4/2/26.
//

import SwiftUI
import SwiftData
import Photos
import OSLog

private let resultsLogger = Logger(subsystem: "Vesper", category: "Results")
import StoreKit

/// width / height — falls back to 1 for zero-sized placeholders so SwiftUI never sees NaN.
private extension UIImage {
    var safeAspectRatio: CGFloat {
        guard size.height > 0, size.width > 0 else { return 1 }
        return size.width / size.height
    }
}

private extension PHAuthorizationStatus {
    var vesperCanMutateSelectedAssets: Bool {
        self == .authorized || self == .limited
    }
}

struct ResultsView: View {
    let initialTopPicks: [PhotoResult]
    let initialRunnerUps: [PhotoResult]
    let initialDeleteCandidates: [PhotoResult]
    let initialSimilars: [PhotoResult]

    @State private var topPicks: [PhotoResult]
    @State private var runnerUps: [PhotoResult]
    @State private var deleteCandidates: [PhotoResult]
    @State private var similars: [PhotoResult]
    @State private var targetTopPickCount: Int
    @State private var showRunnerUps = false
    @State private var showDeleteCandidates = false
    @State private var showSimilars = false
    @State private var galleryStartIndex: Int? = nil
    @State private var galleryPool: GalleryPool = .topPicks
    @State private var showAlbumSavedToast = false
    @State private var albumToastText = "Saved to Photos album"
    @State private var showPromotedToast = false
    @State private var showRerankedToast = false
    @State private var isSyncingRatingAlbums = false
    @State private var hasDeferredRerank = false
    @State private var sessionFeedback: [UUID: GalleryView.FeedbackState] = [:]
    #if DEBUG
    @State private var showAIDiagnostics = false
    #endif
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteAllConfirm = false
    @State private var showPhotoLibraryAccessAlert = false
    @State private var showPhotoIdentifierUnavailableAlert = false
    @State private var isMultiSelectingDeletes = false
    @State private var selectedDeleteIndices: Set<Int> = []
    @State private var showMultiDeleteConfirm = false
    @State private var isMultiSelectingSimilars = false
    @State private var selectedSimilarIndices: Set<Int> = []
    @State private var showMultiSimilarDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @AppStorage("completedBatchCount") private var completedBatchCount = 0
    @AppStorage("autoCreateRatingAlbums") private var autoCreateRatingAlbums = true
    // Ensures `completedBatchCount` only increments once per ResultsView
    // instance — a re-appear from a pushed detail view otherwise inflates the
    // count and would trigger the review prompt too early.
    @State private var didCountThisBatch = false

    enum GalleryPool { case topPicks, runnerUps, deleteCandidates, similars, ratingBucket(Int) }

    let isDatingMode: Bool
    let purposeTag: String
    let onRerun: (() -> Void)?

    init(topPicks: [PhotoResult], runnerUps: [PhotoResult], deleteCandidates: [PhotoResult] = [], similars: [PhotoResult] = [], isDatingMode: Bool = false, purposeTag: String = "", onRerun: (() -> Void)? = nil) {
        self.initialTopPicks = topPicks
        self.initialRunnerUps = runnerUps
        self.initialDeleteCandidates = deleteCandidates
        self.initialSimilars = similars
        self.isDatingMode = isDatingMode
        self.purposeTag = purposeTag
        self.onRerun = onRerun
        _topPicks = State(initialValue: topPicks)
        _runnerUps = State(initialValue: runnerUps)
        _deleteCandidates = State(initialValue: deleteCandidates)
        _similars = State(initialValue: similars)
        _targetTopPickCount = State(initialValue: topPicks.count)
    }

    let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                if topPicks.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(Color.vesperAccent.opacity(0.5))
                        Text("No picks found")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Text("Try a different category, fewer photos, or add reference photos to help Vesper understand your style.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            dismiss()
                        } label: {
                            Text("Try Again")
                                .vesperPrimaryButton()
                        }
                        .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    // Header
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isDatingMode ? "Best Dating Photos" : "Top Picks")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                            Text("Review, rate, then save or organize your picks")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                        #if DEBUG
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showAIDiagnostics = true
                        } label: {
                            Image(systemName: "waveform.path.ecg.rectangle")
                                .font(.caption.bold())
                                .foregroundStyle(Color.vesperAccent)
                                .frame(width: 32, height: 32)
                                .background(Color.vesperAccent.opacity(0.12))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.vesperAccent.opacity(0.20), lineWidth: 1))
                        }
                        .accessibilityLabel("Why these picks? Advanced details")
                        #endif
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            saveTopPicksToAlbum()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.caption.bold())
                                Text("Save Top Picks")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(LinearGradient.vesperGold)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .overlay(alignment: .bottom) {
                        if showAlbumSavedToast || showRerankedToast {
                            HStack(spacing: 6) {
                                Image(systemName: showAlbumSavedToast ? "checkmark.circle.fill" : "arrow.up.arrow.down.circle.fill")
                                    .foregroundStyle(showAlbumSavedToast ? .green : Color.vesperAccent)
                                Text(showAlbumSavedToast ? albumToastText : "Results updated from your feedback")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .offset(y: 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    guidedReviewSection
                    batchSummarySection

                    if isDatingMode {
                        // Dating mode: uniform 3-column grid — no oversized hero
                        let datingColumns = [GridItem(.flexible(), spacing: 6),
                                             GridItem(.flexible(), spacing: 6),
                                             GridItem(.flexible(), spacing: 6)]
                        LazyVGrid(columns: datingColumns, spacing: 6) {
                            ForEach(Array(topPicks.enumerated()), id: \.element.id) { index, result in
                                ZStack(alignment: .topLeading) {
                                    Image(uiImage: result.image)
                                        .resizable()
                                        .aspectRatio(result.image.safeAspectRatio, contentMode: .fit)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .onTapGesture {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            openGallery(index: index, isTopPicks: true)
                                        }
                                    rankBadge(index + 1).padding(6)
                                }
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        // Standard mode: large hero for #1, 2-column grid for the rest
                        if let hero = topPicks.first {
                            ZStack(alignment: .topLeading) {
                                Image(uiImage: hero.image)
                                    .resizable()
                                    .aspectRatio(hero.image.safeAspectRatio, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                    .onTapGesture {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        openGallery(index: 0, isTopPicks: true)
                                    }
                                rankBadge(1).padding(12)
                                scoreBadge(hero.compositeScore)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                    .padding(10)
                            }
                            .padding(.horizontal)
                        }

                        if topPicks.count > 1 {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(Array(topPicks.dropFirst().enumerated()), id: \.element.id) { index, result in
                                    ZStack(alignment: .topLeading) {
                                        Image(uiImage: result.image)
                                            .resizable()
                                            .aspectRatio(result.image.safeAspectRatio, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: 13))
                                            .onTapGesture {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                openGallery(index: index + 1, isTopPicks: true)
                                            }
                                        rankBadge(index + 2).padding(8)
                                        scoreBadge(result.compositeScore)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                            .padding(8)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Runner Ups
                    if !runnerUps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeInOut(duration: 0.2)) { showRunnerUps.toggle() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Alternates")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                    Text("Close picks that may be better for your taste. Tap \(Image(systemName: "plus.circle.fill")) to promote.")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text("\(runnerUps.count)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                                Image(systemName: showRunnerUps ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.white.opacity(0.4))
                                    .font(.subheadline)
                                    .padding(.leading, 4)
                            }
                            .padding(.horizontal)
                        }

                        if showRunnerUps {
                            if runnerUps.isEmpty {
                                Text("No separate alternates found. Near-duplicates and low-confidence picks are listed in the sections below.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.42))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal)
                            } else {
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(Array(runnerUps.enumerated()), id: \.element.id) { index, result in
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: result.image)
                                                .resizable()
                                                .aspectRatio(result.image.safeAspectRatio, contentMode: .fit)
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                                .onTapGesture {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    galleryPool = .runnerUps
                                                    galleryStartIndex = index
                                                }
                                            // Promote button: moves this photo to top picks and saves positive preference signal.
                                            Button {
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                                    promoteRunnerUp(at: index)
                                                }
                                            } label: {
                                                ZStack {
                                                    Circle()
                                                        .fill(Color.black.opacity(0.45))
                                                        .frame(width: 28, height: 28)
                                                    Image(systemName: "plus.circle.fill")
                                                        .font(.system(size: 24))
                                                        .foregroundStyle(Color.vesperAccent)
                                                }
                                            }
                                            .padding(6)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }

                            if showPromotedToast {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.vesperAccent)
                                    Text("Added to top picks · saved as a preference signal")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                    }
                    }

                    // Cleanup review section
                    if !deleteCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showDeleteCandidates.toggle()
                                    if !showDeleteCandidates {
                                        isMultiSelectingDeletes = false
                                        selectedDeleteIndices = []
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "trash.circle.fill")
                                                .foregroundStyle(.red.opacity(0.7))
                                            Text("Cleanup Review")
                                                .font(.title2.bold())
                                                .foregroundStyle(.white)
                                        }
                                        Text("Suggested low-priority photos. Nothing is deleted until you confirm.")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.4))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Text("\(deleteCandidates.count)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.red.opacity(0.8))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.red.opacity(0.12))
                                        .clipShape(Capsule())
                                    if showDeleteCandidates {
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                isMultiSelectingDeletes.toggle()
                                                selectedDeleteIndices = []
                                            }
                                        } label: {
                                            Text(isMultiSelectingDeletes ? "Done" : "Select")
                                                .font(.caption.bold())
                                                .foregroundStyle(isMultiSelectingDeletes ? Color.vesperAccent : .white.opacity(0.6))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.white.opacity(0.08))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    if !isMultiSelectingDeletes {
                                        Button {
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            showDeleteAllConfirm = true
                                        } label: {
                                            Text("Delete Suggestions")
                                                .font(.caption.bold())
                                                .foregroundStyle(.red.opacity(0.85))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.red.opacity(0.12))
                                                .clipShape(Capsule())
                                                .overlay(Capsule().stroke(.red.opacity(0.2), lineWidth: 1))
                                        }
                                    }
                                    Image(systemName: showDeleteCandidates ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.white.opacity(0.4))
                                        .font(.subheadline)
                                }
                                .padding(.horizontal)
                            }
                            .confirmationDialog(
                                "Move \(deleteCandidates.count) cleanup suggestion\(deleteCandidates.count == 1 ? "" : "s") to Recently Deleted?",
                                isPresented: $showDeleteAllConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Move to Recently Deleted", role: .destructive) { deleteAllDeleteCandidates() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This moves these photos to Recently Deleted in Photos. You can recover them for 30 days.")
                            }
                            .confirmationDialog(
                                "Move \(selectedDeleteIndices.count) selected cleanup suggestion\(selectedDeleteIndices.count == 1 ? "" : "s") to Recently Deleted?",
                                isPresented: $showMultiDeleteConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Move to Recently Deleted", role: .destructive) { deleteSelectedDeleteCandidates() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This moves these photos to Recently Deleted in Photos. You can recover them for 30 days.")
                            }

                            if showDeleteCandidates {
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(Array(deleteCandidates.enumerated()), id: \.element.id) { index, result in
                                        let isSelected = selectedDeleteIndices.contains(index)
                                        ZStack(alignment: .bottomLeading) {
                                            Image(uiImage: result.image)
                                                .resizable()
                                                .aspectRatio(result.image.safeAspectRatio, contentMode: .fit)
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                                .overlay(RoundedRectangle(cornerRadius: 13).fill(
                                                    isSelected ? .red.opacity(0.25) : .red.opacity(0.08)
                                                ))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 13)
                                                        .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
                                                )
                                                .onTapGesture {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    if isMultiSelectingDeletes {
                                                        if isSelected { selectedDeleteIndices.remove(index) }
                                                        else { selectedDeleteIndices.insert(index) }
                                                    } else {
                                                        galleryPool = .deleteCandidates
                                                        galleryStartIndex = index
                                                    }
                                                }
                                            Text(deleteBadgeLabel(result))
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 4)
                                                .background(.red.opacity(0.75))
                                                .clipShape(Capsule())
                                                .padding(7)
                                            // Checkmark overlay in multi-select mode
                                            if isMultiSelectingDeletes {
                                                ZStack {
                                                    Circle()
                                                        .fill(isSelected ? Color.red : Color.black.opacity(0.4))
                                                        .frame(width: 24, height: 24)
                                                    if isSelected {
                                                        Image(systemName: "checkmark")
                                                            .font(.system(size: 11, weight: .bold))
                                                            .foregroundStyle(.white)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                                .padding(7)
                                            }
                                        }
                                        .scaleEffect(isMultiSelectingDeletes && isSelected ? 0.95 : 1.0)
                                        .animation(.spring(response: 0.2), value: isSelected)
                                    }
                                }
                                .padding(.horizontal)

                                if isMultiSelectingDeletes && !selectedDeleteIndices.isEmpty {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        showMultiDeleteConfirm = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "trash.fill")
                                            Text("Delete \(selectedDeleteIndices.count) Suggested")
                                                .font(.subheadline.bold())
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(.red.opacity(0.8))
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    .padding(.horizontal)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                        }
                    }

                    // Duplicate/similar photos section — burst shots and same-scene variants
                    if !similars.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showSimilars.toggle()
                                    if !showSimilars {
                                        isMultiSelectingSimilars = false
                                        selectedSimilarIndices = []
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "square.on.square.fill")
                                                .foregroundStyle(.blue.opacity(0.7))
                                            Text("Duplicates / Similar")
                                                .font(.title2.bold())
                                                .foregroundStyle(.white)
                                        }
                                        Text("Near-identical frames. Keep your favorite before removing extras.")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    Spacer()
                                    Text("\(similars.count)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.blue.opacity(0.8))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.blue.opacity(0.12))
                                        .clipShape(Capsule())
                                    if showSimilars {
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                isMultiSelectingSimilars.toggle()
                                                selectedSimilarIndices = []
                                            }
                                        } label: {
                                            Text(isMultiSelectingSimilars ? "Done" : "Select")
                                                .font(.caption.bold())
                                                .foregroundStyle(isMultiSelectingSimilars ? Color.vesperAccent : .white.opacity(0.6))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.white.opacity(0.08))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Image(systemName: showSimilars ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.white.opacity(0.4))
                                        .font(.subheadline)
                                }
                                .padding(.horizontal)
                            }
                            .confirmationDialog(
                                "Move \(selectedSimilarIndices.count) similar photo\(selectedSimilarIndices.count == 1 ? "" : "s") to Recently Deleted?",
                                isPresented: $showMultiSimilarDeleteConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Move to Recently Deleted", role: .destructive) { deleteSelectedSimilars() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This moves these photos to Recently Deleted in Photos. You can recover them for 30 days.")
                            }

                            if showSimilars {
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(Array(similars.enumerated()), id: \.element.id) { index, result in
                                        let isSelected = selectedSimilarIndices.contains(index)
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: result.image)
                                                .resizable()
                                                .aspectRatio(result.image.safeAspectRatio, contentMode: .fit)
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 13)
                                                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                                                )
                                                .onTapGesture {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    if isMultiSelectingSimilars {
                                                        if isSelected { selectedSimilarIndices.remove(index) }
                                                        else { selectedSimilarIndices.insert(index) }
                                                    } else {
                                                        galleryPool = .similars
                                                        galleryStartIndex = index
                                                    }
                                                }
                                            if isMultiSelectingSimilars {
                                                ZStack {
                                                    Circle()
                                                        .fill(isSelected ? Color.blue : Color.black.opacity(0.4))
                                                        .frame(width: 24, height: 24)
                                                    if isSelected {
                                                        Image(systemName: "checkmark")
                                                            .font(.system(size: 11, weight: .bold))
                                                            .foregroundStyle(.white)
                                                    }
                                                }
                                                .padding(7)
                                            }
                                        }
                                        .scaleEffect(isMultiSelectingSimilars && isSelected ? 0.95 : 1.0)
                                        .animation(.spring(response: 0.2), value: isSelected)
                                    }
                                }
                                .padding(.horizontal)

                                if isMultiSelectingSimilars && !selectedSimilarIndices.isEmpty {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        showMultiSimilarDeleteConfirm = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "trash.fill")
                                            Text("Delete \(selectedSimilarIndices.count) Similar")
                                                .font(.subheadline.bold())
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(.red.opacity(0.8))
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    .padding(.horizontal)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                        }
                    }

                    ratingAlbumsSection

                    // Bottom actions
                    VStack(spacing: 10) {
                        if let onRerun {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onRerun()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("Rerun with Different Settings")
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.vesperAccent.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.vesperAccent.opacity(0.3), lineWidth: 1))
                            }
                        }
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("New Batch")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .vesperCard(cornerRadius: 14)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 52)
        }
        .vesperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Ask for review after 2nd completed batch — enough signal that the
            // user finds it useful. Guarded so nested-view onAppear re-fires
            // don't double-count. Delay is long enough for the user to settle
            // into the results screen before the prompt overlays it.
            guard !didCountThisBatch else { return }
            didCountThisBatch = true
            completedBatchCount += 1
            if completedBatchCount == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    requestReview()
                }
            }
        }
        .alert("Photos Access Required", isPresented: $showPhotoLibraryAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To save albums or delete photos, allow Vesper access to the selected photos or full access in Settings.")
        }
        .alert("Photo Unavailable", isPresented: $showPhotoIdentifierUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Some photos are missing their Photos library identifier, so Vesper cannot delete them from your iPhone.")
        }
        #if DEBUG
        .sheet(isPresented: $showAIDiagnostics) {
            AIDiagnosticsView(
                topPicks: topPicks,
                runnerUps: runnerUps,
                deleteCandidates: deleteCandidates,
                similars: similars,
                ratings: Dictionary(uniqueKeysWithValues: sessionFeedback.map { ($0.key, $0.value.starRating) })
            )
        }
        #endif
        .fullScreenCover(isPresented: Binding(
            get: { galleryStartIndex != nil },
            set: { if !$0 { dismissGallery() } }
        )) {
            galleryCover
        }
    }

    private var guidedReviewSection: some View {
        let rated = ratedTopPickCount
        let total = max(topPicks.count, 1)
        let cleanupCount = deleteCandidates.count + similars.count
        let ctaTitle = rated == 0 ? "Start Review" : (rated < topPicks.count ? "Continue Review" : "Review Again")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checklist.checked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.vesperAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.vesperAccent.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review this batch")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(nextReviewStepText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("\(rated)/\(total)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(Color.vesperAccent.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.vesperAccent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel("\(rated) of \(total) top picks rated")
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                galleryPool = .topPicks
                galleryStartIndex = firstUnratedTopPickIndex ?? 0
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.caption.bold())
                    Text(ctaTitle)
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(rated)/\(topPicks.count)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.black.opacity(0.62))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(LinearGradient.vesperGold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(topPicks.isEmpty)
            .accessibilityHint("Opens the first unrated top pick")

            HStack(spacing: 8) {
                reviewStepChip(icon: "star.fill", title: "Rate", value: "\(rated)", tint: Color.vesperAccent)
                reviewStepChip(icon: "folder", title: "Sort", value: "\(ratedPhotoCount)", tint: .green)
                reviewStepChip(icon: "tray.and.arrow.down", title: "Review", value: "\(cleanupCount)", tint: .red)
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 14, height: 14)
                Text("Nothing is deleted or added to Photos albums unless you confirm or keep automatic star albums on.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal)
    }

    private var batchSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.vesperAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.vesperAccent.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Batch Summary")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(batchSummaryText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                summaryMetric(title: "Top", value: "\(topPicks.count)", tint: Color.vesperAccent)
                summaryMetric(title: "Alt", value: "\(runnerUps.count)", tint: .cyan)
                summaryMetric(title: "Rated", value: "\(ratedPhotoCount)", tint: .green)
                summaryMetric(title: "Review", value: "\(deleteCandidates.count + similars.count)", tint: .red)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.vesperAccent.opacity(0.8))
                    .frame(width: 15, height: 15)
                Text(learningSummaryText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal)
    }

    private func summaryMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.bold().monospacedDigit())
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.14), lineWidth: 1))
    }

    private func reviewStepChip(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Text(value)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.14), lineWidth: 1))
    }

    private var ratedPhotoCount: Int {
        sessionFeedback.values.count
    }

    private var ratedTopPickCount: Int {
        topPicks.filter { sessionFeedback[$0.id] != nil }.count
    }

    private var highRatedCount: Int {
        sessionFeedback.values.filter { $0.starRating >= 4 }.count
    }

    private var neutralRatedCount: Int {
        sessionFeedback.values.filter { $0.starRating == 3 }.count
    }

    private var lowRatedCount: Int {
        sessionFeedback.values.filter { $0.starRating <= 2 }.count
    }

    private var firstUnratedTopPickIndex: Int? {
        topPicks.firstIndex { sessionFeedback[$0.id] == nil }
    }

    private var batchSummaryText: String {
        if ratedPhotoCount == 0 {
            return "Vesper found \(topPicks.count) top pick\(topPicks.count == 1 ? "" : "s") and \(runnerUps.count) alternate\(runnerUps.count == 1 ? "" : "s"). Rate photos to turn this into a personalized batch."
        }
        return "\(highRatedCount) preferred, \(neutralRatedCount) backup, \(lowRatedCount) cleanup signal\(lowRatedCount == 1 ? "" : "s") saved from this batch."
    }

    private var learningSummaryText: String {
        if ratedPhotoCount == 0 {
            return "No preference signal yet. One rating is useful, but patterns get stronger after a few high and low examples."
        }
        if highRatedCount > 0 && lowRatedCount > 0 {
            return "This batch gives Vesper contrast: what to prefer and what to avoid in similar photo contexts."
        }
        if highRatedCount > 0 {
            return "Positive examples are saved. Add a few low ratings when photos miss your taste so Vesper learns the boundary."
        }
        if lowRatedCount > 0 {
            return "Cleanup signals are saved. Add a few strong ratings too so Vesper knows what to aim for."
        }
        return "Backup ratings are saved as neutral context, so they organize the batch without pushing the model too hard."
    }

    private var nextReviewStepText: String {
        if ratedTopPickCount == 0 {
            return "Start with top picks. Ratings teach future batches on this device."
        }
        if !deleteCandidates.isEmpty {
            return "Cleanup suggestions are review-only until you confirm deletion."
        }
        if !runnerUps.isEmpty {
            return "Alternates are waiting below if a top pick is not quite right."
        }
        return "Your ratings are saved. Open star groups or start another batch."
    }

    private var galleryCover: some View {
        let pool = galleryPool
        let photos = galleryPhotos(for: pool)
        let startIndex = galleryStartIndex ?? 0
        let showReasoning = galleryShowsReasoning(pool)
        let contextScores = allVisibleResults

        return GalleryView(
            photos: photos,
            startIndex: startIndex,
            showReasoning: showReasoning,
            purposeTag: purposeTag,
            allPhotoScores: contextScores,
            onDelete: { index in
                handleGalleryDelete(index: index, pool: pool, galleryPhotos: photos)
            },
            onFeedbackChange: { photoID, state in
                applyLiveFeedback(photoID: photoID, state: state)
            },
            onDismiss: {
                dismissGallery()
            }
        )
    }

    private func galleryPhotos(for pool: GalleryPool) -> [PhotoResult] {
        switch pool {
        case .topPicks: return topPicks
        case .runnerUps: return runnerUps
        case .deleteCandidates: return deleteCandidates
        case .similars: return similars
        case .ratingBucket(let rating): return ratedPhotos(starRating: rating)
        }
    }

    private func galleryShowsReasoning(_ pool: GalleryPool) -> Bool {
        switch pool {
        case .topPicks, .runnerUps: return true
        case .deleteCandidates, .similars, .ratingBucket: return false
        }
    }

    private func handleGalleryDelete(index: Int, pool: GalleryPool, galleryPhotos: [PhotoResult]) {
        switch pool {
        case .topPicks:
            guard topPicks.indices.contains(index) else { return }
            topPicks.remove(at: index)
        case .runnerUps:
            guard runnerUps.indices.contains(index) else { return }
            runnerUps.remove(at: index)
        case .deleteCandidates:
            guard deleteCandidates.indices.contains(index) else { return }
            deleteCandidates.remove(at: index)
        case .similars:
            guard similars.indices.contains(index) else { return }
            similars.remove(at: index)
        case .ratingBucket:
            guard galleryPhotos.indices.contains(index) else { return }
            let photoID = galleryPhotos[index].id
            removePhotoFromAllPools(photoID: photoID)
        }
    }

    private var ratingAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Star Ratings")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Open photos by rating or sync them into Photos albums.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    syncRatedPhotosToAlbums()
                } label: {
                    HStack(spacing: 5) {
                        if isSyncingRatingAlbums {
                            ProgressView()
                                .scaleEffect(0.62)
                                .tint(.black)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption.bold())
                        }
                        Text("Sync")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(ratedPhotoCount == 0 ? Color.white.opacity(0.24) : Color.vesperAccent)
                    .clipShape(Capsule())
                }
                .disabled(ratedPhotoCount == 0 || isSyncingRatingAlbums)
                .accessibilityLabel("Sync rated photos to Photos albums")
                Toggle("", isOn: $autoCreateRatingAlbums)
                    .labelsHidden()
                    .tint(Color.vesperAccent)
                    .accessibilityLabel("Create Photos albums automatically")
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                Image(systemName: autoCreateRatingAlbums ? "folder.badge.plus" : "folder")
                    .font(.caption)
                    .foregroundStyle(Color.vesperAccent.opacity(0.8))
                    .frame(width: 18)
                Text(autoCreateRatingAlbums ? "New ratings are added to Vesper star albums automatically. Sync backfills this batch." : "Star ratings stay in Vesper unless you turn albums back on or tap Sync.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(12)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach((1...5).reversed(), id: \.self) { rating in
                    let photos = ratedPhotos(starRating: rating)
                    Button {
                        guard !photos.isEmpty else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        galleryPool = .ratingBucket(rating)
                        galleryStartIndex = 0
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: ratingAlbumIcon(rating))
                                .font(.system(size: 18, weight: .semibold))
                            Text("\(rating)")
                                .font(.headline.monospacedDigit())
                            Text("\(photos.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.52))
                            Text(photos.count == 1 ? "photo" : "photos")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.34))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(photos.isEmpty ? .white.opacity(0.24) : ratingTint(rating))
                        .frame(maxWidth: .infinity)
                        .frame(height: 94)
                        .background(ratingTint(rating).opacity(photos.isEmpty ? 0.04 : 0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ratingTint(rating).opacity(photos.isEmpty ? 0.08 : 0.20), lineWidth: 1))
                    }
                    .disabled(photos.isEmpty)
                    .accessibilityLabel("\(rating) star group")
                    .accessibilityValue("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                }
            }
            .padding(.horizontal)
        }
    }

    private func dismissGallery() {
        galleryStartIndex = nil
        guard hasDeferredRerank else { return }
        hasDeferredRerank = false
        applyFeedbackDrivenPoolChanges()
        rerankTopAndReviewPools()
        withAnimation(.spring(response: 0.35)) { showRerankedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.35)) { showRerankedToast = false }
        }
    }

    private func openGallery(index: Int, isTopPicks: Bool) {
        galleryPool = isTopPicks ? .topPicks : .runnerUps
        galleryStartIndex = index
    }

    private var allVisibleResults: [PhotoResult] {
        uniqueResults(topPicks + runnerUps + deleteCandidates + similars)
    }

    private func ratedPhotos(starRating: Int) -> [PhotoResult] {
        allVisibleResults.filter { result in
            sessionFeedback[result.id]?.starRating == starRating
        }
    }

    private func uniqueResults(_ results: [PhotoResult]) -> [PhotoResult] {
        var seen = Set<UUID>()
        var unique: [PhotoResult] = []
        for result in results where !seen.contains(result.id) {
            seen.insert(result.id)
            unique.append(result)
        }
        return unique
    }

    private func ratingTint(_ rating: Int) -> Color {
        switch rating {
        case 5: return .green
        case 4: return Color.vesperAccent
        case 3: return .orange
        default: return .red
        }
    }

    private func ratingAlbumIcon(_ rating: Int) -> String {
        switch rating {
        case 5: return "star.fill"
        case 4: return "star.leadinghalf.filled"
        case 3: return "star"
        default: return "star.slash.fill"
        }
    }

    private func applyLiveFeedback(photoID: UUID, state: GalleryView.FeedbackState?) {
        if let state {
            sessionFeedback[photoID] = state
        } else {
            sessionFeedback.removeValue(forKey: photoID)
        }

        guard allVisibleResults.contains(where: { $0.id == photoID }) else { return }

        if galleryStartIndex != nil {
            hasDeferredRerank = true
            return
        }

        applyFeedbackDrivenPoolChanges()
        rerankTopAndReviewPools()
        withAnimation(.spring(response: 0.35)) { showRerankedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.35)) { showRerankedToast = false }
        }
    }

    private func rerankTopAndReviewPools() {
        let combined = topPicks + runnerUps
        guard combined.count > 1 else { return }
        let targetTopCount = max(1, min(targetTopPickCount, combined.count))

        let sorted = combined.sorted {
            liveAdjustedScore($0) > liveAdjustedScore($1)
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            topPicks = Array(sorted.prefix(targetTopCount))
            runnerUps = Array(sorted.dropFirst(targetTopCount))
        }
    }

    private func liveAdjustedScore(_ result: PhotoResult) -> Float {
        var score = result.compositeScore
        if let rating = sessionFeedback[result.id]?.starRating {
            switch rating {
            case 5: score += 0.18
            case 4: score += 0.09
            case 3: break
            case 2: score -= 0.12
            default: score -= 0.25
            }
        }
        return score
    }

    private func applyFeedbackDrivenPoolChanges() {
        var changedDeleteSelection = false
        var changedSimilarSelection = false

        for (photoID, state) in sessionFeedback {
            guard let result = findResult(photoID: photoID) else { continue }
            let rating = state.starRating

            switch rating {
            case 4...5:
                if removePhoto(photoID: photoID, from: &deleteCandidates) { changedDeleteSelection = true }
                if removePhoto(photoID: photoID, from: &similars) { changedSimilarSelection = true }
                if !topPicks.contains(where: { $0.id == photoID }) &&
                   !runnerUps.contains(where: { $0.id == photoID }) {
                    runnerUps.append(result)
                }
            case 3:
                if removePhoto(photoID: photoID, from: &deleteCandidates) { changedDeleteSelection = true }
                if !topPicks.contains(where: { $0.id == photoID }) &&
                   !runnerUps.contains(where: { $0.id == photoID }) &&
                   !similars.contains(where: { $0.id == photoID }) {
                    runnerUps.append(result)
                }
            default:
                if removePhoto(photoID: photoID, from: &topPicks) {
                    targetTopPickCount = max(targetTopPickCount, initialTopPicks.count)
                }
                removePhoto(photoID: photoID, from: &runnerUps)
                if removePhoto(photoID: photoID, from: &similars) { changedSimilarSelection = true }
                if !deleteCandidates.contains(where: { $0.id == photoID }) {
                    deleteCandidates.append(result)
                    changedDeleteSelection = true
                }
            }
        }

        if changedDeleteSelection {
            selectedDeleteIndices = []
            isMultiSelectingDeletes = false
        }
        if changedSimilarSelection {
            selectedSimilarIndices = []
            isMultiSelectingSimilars = false
        }
    }

    @discardableResult
    private func removePhoto(photoID: UUID, from results: inout [PhotoResult]) -> Bool {
        let oldCount = results.count
        results.removeAll { $0.id == photoID }
        return results.count != oldCount
    }

    private func removePhotoFromAllPools(photoID: UUID) {
        removePhoto(photoID: photoID, from: &topPicks)
        removePhoto(photoID: photoID, from: &runnerUps)
        removePhoto(photoID: photoID, from: &deleteCandidates)
        removePhoto(photoID: photoID, from: &similars)
        sessionFeedback.removeValue(forKey: photoID)
        selectedDeleteIndices = []
        selectedSimilarIndices = []
    }

    private func findResult(photoID: UUID) -> PhotoResult? {
        topPicks.first { $0.id == photoID } ??
        runnerUps.first { $0.id == photoID } ??
        deleteCandidates.first { $0.id == photoID } ??
        similars.first { $0.id == photoID }
    }

    // MARK: - Bulk actions

    private func saveTopPicksToAlbum() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else {
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { new in
                    DispatchQueue.main.async {
                        if new.vesperCanMutateSelectedAssets { saveTopPicksToAlbum() }
                        else { showPhotoLibraryAccessAlert = true }
                    }
                }
            } else { showPhotoLibraryAccessAlert = true }
            return
        }

        let assetIds = topPicks.compactMap { $0.assetIdentifier.isEmpty ? nil : $0.assetIdentifier }
        guard !assetIds.isEmpty else { return }

        let albumName = "Vesper — \(Date().formatted(date: .abbreviated, time: .omitted))"
        var albumPlaceholder: PHObjectPlaceholder?

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            albumPlaceholder = req.placeholderForCreatedAssetCollection
        }) { success, _ in
            guard success, let ph = albumPlaceholder else { return }
            let cols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [ph.localIdentifier], options: nil)
            guard let album = cols.firstObject else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
            }) { success2, _ in
                DispatchQueue.main.async {
                    if success2 {
                        albumToastText = "Saved top picks to Photos"
                        withAnimation(.spring(response: 0.4)) { showAlbumSavedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { showAlbumSavedToast = false }
                        }
                    }
                }
            }
        }
    }

    private func syncRatedPhotosToAlbums() {
        let assignments = allVisibleResults.compactMap { result -> (assetId: String, rating: Int)? in
            guard let rating = sessionFeedback[result.id]?.starRating,
                  !result.assetIdentifier.isEmpty else { return nil }
            return (result.assetIdentifier, rating)
        }
        guard !assignments.isEmpty else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else {
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { new in
                    DispatchQueue.main.async {
                        if new.vesperCanMutateSelectedAssets { syncRatedPhotosToAlbums() }
                        else { showPhotoLibraryAccessAlert = true }
                    }
                }
            } else {
                showPhotoLibraryAccessAlert = true
            }
            return
        }

        performRatingAlbumSync(assignments: assignments)
    }

    private func performRatingAlbumSync(assignments: [(assetId: String, rating: Int)]) {
        isSyncingRatingAlbums = true
        let albums = existingRatingAlbums()
        let normalized = assignments.map { (assetId: $0.assetId, rating: min(max($0.rating, 1), 5)) }

        PHPhotoLibrary.shared().performChanges {
            for (albumRating, album) in albums {
                let idsToRemove = normalized
                    .filter { $0.rating != albumRating }
                    .map(\.assetId)
                guard !idsToRemove.isEmpty else { continue }
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: idsToRemove, options: nil)
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
            }

            for rating in 1...5 {
                let ids = normalized
                    .filter { $0.rating == rating }
                    .map(\.assetId)
                guard !ids.isEmpty else { continue }

                if let album = albums[rating] {
                    let idsToAdd = ids.filter { !ratingAlbum(album, containsAssetID: $0) }
                    guard !idsToAdd.isEmpty else { continue }
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: idsToAdd, options: nil)
                    PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
                } else {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: ratingAlbumTitle(rating))
                    request.addAssets(assets)
                }
            }
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSyncingRatingAlbums = false
                if success {
                    albumToastText = "Synced star albums"
                    withAnimation(.spring(response: 0.4)) { showAlbumSavedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { showAlbumSavedToast = false }
                    }
                } else if let error {
                    resultsLogger.error("Rating album sync failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func existingRatingAlbums() -> [Int: PHAssetCollection] {
        var albums: [Int: PHAssetCollection] = [:]
        for rating in 1...5 {
            if let album = fetchAlbum(named: ratingAlbumTitle(rating)) {
                albums[rating] = album
            }
        }
        return albums
    }

    private func fetchAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }

    private func ratingAlbum(_ album: PHAssetCollection, containsAssetID assetId: String) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier = %@", assetId)
        return PHAsset.fetchAssets(in: album, options: options).firstObject != nil
    }

    private func ratingAlbumTitle(_ rating: Int) -> String {
        "Vesper - \(rating) Star\(rating == 1 ? "" : "s")"
    }

    private func deleteAllDeleteCandidates() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else {
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { new in
                    DispatchQueue.main.async {
                        if new.vesperCanMutateSelectedAssets { deleteAllDeleteCandidates() }
                        else { showPhotoLibraryAccessAlert = true }
                    }
                }
            } else { showPhotoLibraryAccessAlert = true }
            return
        }

        let deletableResults = deleteCandidates.filter { !$0.assetIdentifier.isEmpty }
        let assetIds = deletableResults.map(\.assetIdentifier)
        guard !assetIds.isEmpty else {
            showPhotoIdentifierUnavailableAlert = true
            return
        }
        let deletedIDs = Set(deletableResults.map(\.id))

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    recordDeletionFeedback(for: deletableResults)
                    deleteCandidates.removeAll { deletedIDs.contains($0.id) }
                    selectedDeleteIndices = []
                    isMultiSelectingDeletes = false
                }
            }
        }
    }

    private func deleteSelectedDeleteCandidates() {
        let selectedResults = selectedDeleteIndices
            .filter { deleteCandidates.indices.contains($0) }
            .map { deleteCandidates[$0] }
        let deletableResults = selectedResults.filter { !$0.assetIdentifier.isEmpty }
        let assetIds = deletableResults.map(\.assetIdentifier)
        guard !assetIds.isEmpty else {
            showPhotoIdentifierUnavailableAlert = true
            return
        }
        let deletedIDs = Set(deletableResults.map(\.id))

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else { showPhotoLibraryAccessAlert = true; return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    recordDeletionFeedback(for: deletableResults)
                    deleteCandidates.removeAll { deletedIDs.contains($0.id) }
                    selectedDeleteIndices = []
                    isMultiSelectingDeletes = false
                }
            }
        }
    }

    private func deleteSelectedSimilars() {
        let selectedResults = selectedSimilarIndices
            .filter { similars.indices.contains($0) }
            .map { similars[$0] }
        let deletableResults = selectedResults.filter { !$0.assetIdentifier.isEmpty }
        let assetIds = deletableResults.map(\.assetIdentifier)
        guard !assetIds.isEmpty else {
            showPhotoIdentifierUnavailableAlert = true
            return
        }
        let deletedIDs = Set(deletableResults.map(\.id))

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else { showPhotoLibraryAccessAlert = true; return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    recordDeletionFeedback(for: deletableResults)
                    similars.removeAll { deletedIDs.contains($0.id) }
                    selectedSimilarIndices = []
                    isMultiSelectingSimilars = false
                }
            }
        }
    }

    private func promoteRunnerUp(at index: Int) {
        guard index < runnerUps.count else { return }
        let result = runnerUps.remove(at: index)
        topPicks.append(result)
        targetTopPickCount = max(targetTopPickCount, topPicks.count)

        // Save positive feedback so future batches understand this preference.
        Task {
            let imageEmb: [Float]
            if let embedder = CLIPEmbedder.shared,
               let embedding = await embedder.embedAsync(image: result.image) {
                imageEmb = embedding
            } else {
                imageEmb = []
            }

            let feedback = PhotoFeedback(
                liked: true, isNeutral: false, reason: "",
                imageEmbedding: imageEmb, reasonEmbedding: [],
                purposeTag: purposeTag,
                qualityScore: result.qualityScore,
                exposureScore: result.exposureScore,
                compositionScore: result.compositionScore,
                genuineSmileScore: result.genuineSmileScore,
                contrastEmbedding: [],
                faceYaw: result.faceYaw,
                eyeOpenConfidence: result.eyeOpenConfidence,
                colorHarmonyScore: result.colorHarmonyScore,
                referenceScore: result.referenceScore ?? 0.5,
                userFaceIdentified: result.userFaceIdentified,
                starRating: 5
            )
            modelContext.insert(feedback)
            do {
                try modelContext.save()
            } catch {
                resultsLogger.error("Save promoted feedback failed: \(error.localizedDescription, privacy: .private)")
            }
        }

        showPromotedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.4)) { showPromotedToast = false }
        }
    }

    private func recordDeletionFeedback(for results: [PhotoResult]) {
        guard !results.isEmpty else { return }
        Task {
            for result in results {
                let imageEmb = await CLIPEmbedder.shared?.embedAsync(image: result.image) ?? []
                let feedback = PhotoFeedback(
                    liked: false,
                    isNeutral: false,
                    reason: "Deleted from library",
                    imageEmbedding: imageEmb,
                    reasonEmbedding: [],
                    purposeTag: purposeTag,
                    qualityScore: result.qualityScore,
                    exposureScore: result.exposureScore,
                    compositionScore: result.compositionScore,
                    genuineSmileScore: result.genuineSmileScore,
                    contrastEmbedding: [],
                    faceYaw: result.faceYaw,
                    eyeOpenConfidence: result.eyeOpenConfidence,
                    colorHarmonyScore: result.colorHarmonyScore,
                    referenceScore: result.referenceScore ?? 0.5,
                    userFaceIdentified: result.userFaceIdentified,
                    starRating: 1
                )
                modelContext.insert(feedback)
            }
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                resultsLogger.error("Save deletion feedback failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func deleteBadgeLabel(_ result: PhotoResult) -> String {
        if result.qualityScore < 0.20 { return "Blurry" }
        // Only tag "Eyes closed" when the eye analyser actually returned a closed verdict.
        // An `.unknown` reading (sunglasses, profile, squint) must not be labelled as closed.
        if result.hasFace && result.eyeState == .closed && result.eyeOpenConfidence < 0.20 {
            return "Eyes closed"
        }
        if result.qualityScore < 0.38 { return "Low quality" }
        if result.exposureScore < 0.42 { return "Lighting" }
        if result.compositionScore < 0.35 { return "Composition" }
        if result.hasFace && result.eyeState == .closed && result.eyeOpenConfidence < 0.35 {
            return "Check eyes"
        }
        return "Review"
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rank == 1 ? LinearGradient.vesperGold : LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func scoreBadge(_ score: Float) -> some View {
        if score > 0 {
            Text("\(Int(score * 100))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
        }
    }
}

// MARK: - Photo gallery

struct GalleryView: View {
    let photos: [PhotoResult]
    let startIndex: Int
    let showReasoning: Bool
    let onDelete: (Int) -> Void
    let onFeedbackChange: (UUID, FeedbackState?) -> Void
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var feedbackSaved: [UUID: FeedbackState] = [:]
    @State private var feedbackRecords: [UUID: PhotoFeedback] = [:]
    @State private var feedbackReasons: [UUID: String] = [:]
    @State private var savingFeedbackIDs: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var showDeleteFromLibraryConfirm = false
    @State private var showPhotoSharePrompt = false
    @State private var showShareSheet = false
    @State private var favoritedAssetIds: Set<String> = []
    @State private var showPhotoAccessAlert = false
    @State private var showPhotoIdentifierUnavailableAlert = false
    @State private var showLearningToast = false
    @State private var learningToastText = "Rating saved"
    @State private var showFavoritedToast = false
    @State private var pendingFeedbackUploadTasks: [UUID: Task<Void, Never>] = [:]
    /// How long in-screen toasts stay visible before auto-dismissing.
    /// Tuned to ~read-one-line-of-text; matches the spring/ease timings below.
    private static let toastVisibleSeconds: Double = 2.2
    @State private var dragOffset: CGFloat = 0
    @State private var photoScale: CGFloat = 1.0
    @State private var photoLastScale: CGFloat = 1.0
    @State private var pendingFeedbackRating = 5
    @State private var pendingFeedbackReason = ""
    @State private var pendingFeedbackPhotoID: UUID?
    @State private var reasonPhotoID: UUID?
    @AppStorage("hasAnsweredPhotoShare") private var hasAnsweredPhotoShare = false
    @AppStorage("photoShareOptIn") private var photoShareOptIn = false
    @AppStorage("autoCreateRatingAlbums") private var autoCreateRatingAlbums = true
    @Environment(\.modelContext) private var modelContext

    enum FeedbackState: Equatable {
        case rated(Int)

        var starRating: Int {
            switch self {
            case .rated(let rating): return min(max(rating, 1), 5)
            }
        }
    }

    let purposeTag: String
    let allPhotoScores: [PhotoResult]  // full pool (top+runner+etc) for contrastive context

    init(photos: [PhotoResult], startIndex: Int, showReasoning: Bool,
         purposeTag: String = "", allPhotoScores: [PhotoResult] = [],
         onDelete: @escaping (Int) -> Void,
         onFeedbackChange: @escaping (UUID, FeedbackState?) -> Void = { _, _ in },
         onDismiss: @escaping () -> Void) {
        self.photos = photos
        self.startIndex = startIndex
        self.showReasoning = showReasoning
        self.purposeTag = purposeTag
        self.allPhotoScores = allPhotoScores
        self.onDelete = onDelete
        self.onFeedbackChange = onFeedbackChange
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: startIndex)
    }

    var current: PhotoResult? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()
                .opacity(dragOffset > 0 ? Double(1.0 - dragOffset / 400) : 1.0)

            if photos.isEmpty {
                Text("No photos")
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(spacing: 0) {
                    // Photo pages
                    TabView(selection: $currentIndex) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, result in
                            Image(uiImage: result.image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .scaleEffect(index == currentIndex ? photoScale : 1.0)
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let delta = value / photoLastScale
                                            photoLastScale = value
                                            photoScale = min(max(photoScale * delta, 1.0), 5.0)
                                        }
                                        .onEnded { _ in
                                            photoLastScale = 1.0
                                            if photoScale < 1.2 {
                                                withAnimation(.spring(response: 0.3)) { photoScale = 1.0 }
                                            }
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.spring(response: 0.3)) {
                                        photoScale = photoScale > 1.5 ? 1.0 : 2.5
                                    }
                                }
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: currentIndex) { _, _ in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.3)) { photoScale = 1.0 }
                        photoLastScale = 1.0
                    }

                    // Page counter
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 8)

                    // Reasoning (top picks only)
                    if showReasoning, let result = current, !result.reasoning.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Why Vesper ranked this")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.vesperAccent)
                                Spacer()
                                Text("#\(currentIndex + 1) pick")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white.opacity(0.3))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                // Use offset-based IDs so SwiftUI treats each photo's list as unique
                                ForEach(Array(result.reasoning.components(separatedBy: " · ").enumerated()), id: \.offset) { _, reason in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.vesperAccent.opacity(0.6))
                                            .font(.caption)
                                            .padding(.top, 2)
                                        Text(reason)
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vesperCard(cornerRadius: 14)
                        .padding(.horizontal, 16)
                        .id("\(currentIndex)-reasoning")  // forces full re-render on photo change
                    }

                    if let result = current,
                       let comparisonInsight = comparisonInsight(for: result) {
                        comparisonInsightCard(comparisonInsight)
                            .padding(.horizontal, 16)
                            .padding(.top, showReasoning ? 8 : 0)
                    }

                    if let result = current {
                        starRatingControl(result: result)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }

                    if let result = current, feedbackSaved[result.id] != nil {
                        Button {
                            undoFeedback(result: result)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("Undo feedback")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                        }
                        .disabled(savingFeedbackIDs.contains(result.id))
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    // Favorite in Photos app
                    if let result = current {
                        let isFav = favoritedAssetIds.contains(result.assetIdentifier)
                        Button {
                            toggleFavorite(result: result)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isFav ? "heart.fill" : "heart")
                                Text(isFav ? "Favorited in Photos" : "Add to Favorites")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isFav ? Color.vesperAccent : .white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(isFav ? Color.vesperAccent.opacity(0.15) : Color.vesperCard)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(isFav ? Color.vesperAccent.opacity(0.35) : Color.vesperBorder, lineWidth: 1))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    }

                    // Close / Delete row
                    HStack(spacing: 10) {
                        Button { onDismiss() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark")
                                Text("Close")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .vesperCard(cornerRadius: 14)
                        }

                        // Remove from results only
                        Button { showDeleteConfirm = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle")
                                Text("Remove")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.red.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.18), lineWidth: 1))
                        }
                        .confirmationDialog("Remove from results?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                            Button("Remove from Results", role: .destructive) {
                                removeFromResults(at: currentIndex)
                            }
                            Button("Cancel", role: .cancel) {}
                        }

                        // Delete from device library
                        Button { showDeleteFromLibraryConfirm = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .background(.red.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.18), lineWidth: 1))
                        }
                        .accessibilityLabel("Delete from iPhone")
                        .accessibilityHint("Removes this photo from your device library")
                        .confirmationDialog(
                            "Delete from iPhone?",
                            isPresented: $showDeleteFromLibraryConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Delete from Library", role: .destructive) {
                                deleteFromLibrary(at: currentIndex)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This moves the photo to Recently Deleted in Photos. You can recover it for 30 days.")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { v in
                    if v.translation.height > 0 { dragOffset = v.translation.height }
                }
                .onEnded { v in
                    if v.translation.height > 120 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                    }
                }
        )
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if showLearningToast {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "brain.fill")
                            .font(.caption)
                            .foregroundStyle(Color.vesperAccent)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(learningToastText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text("Light signal until more ratings confirm it")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showFavoritedToast {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                        Text("Added to Favorites in Photos")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 56)
        }
        .overlay(alignment: .topTrailing) {
            // Share button — always visible
            if let current {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .padding(.top, 56)
                .padding(.trailing, 20)
                .sheet(isPresented: $showShareSheet) {
                    ShareSheet(items: [current.image])
                }
            }
        }
        .onAppear {
            // Pre-populate which photos are already favorited in Photos
            let ids = photos.map { $0.assetIdentifier }.filter { !$0.isEmpty }
            guard !ids.isEmpty else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var favIds = Set<String>()
            assets.enumerateObjects { asset, _, _ in
                if asset.isFavorite { favIds.insert(asset.localIdentifier) }
            }
            favoritedAssetIds = favIds
        }
        .alert("Photos Access Required", isPresented: $showPhotoAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To organize, favorite, or delete photos, allow Vesper access to the selected photos or full access in Settings.")
        }
        .alert("Photo Unavailable", isPresented: $showPhotoIdentifierUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This photo is missing its Photos library identifier, so Vesper cannot delete it from your iPhone.")
        }
        .sheet(isPresented: $showPhotoSharePrompt) {
            PhotoShareConsentSheet { optIn in
                hasAnsweredPhotoShare = true
                photoShareOptIn = optIn
                let result = pendingFeedbackPhotoID.flatMap { photoID in
                    photos.first { $0.id == photoID }
                }
                if optIn, let result {
                    queueFeedbackUpload(
                        photoID: result.id,
                        starRating: pendingFeedbackRating,
                        reason: pendingFeedbackReason,
                        result: result,
                        thumbnail: result.image
                    )
                }
                showPhotoSharePrompt = false
            }
        }
        .sheet(isPresented: Binding(
            get: { reasonPhotoID != nil },
            set: { if !$0 { reasonPhotoID = nil } }
        )) {
            if let photoID = reasonPhotoID,
               let result = photos.first(where: { $0.id == photoID }) {
                RatingReasonSheet(initialText: feedbackReasons[photoID] ?? "") { reason in
                    let rating = feedbackSaved[photoID]?.starRating ?? 0
                    if rating > 0 {
                        saveStarRating(
                            rating,
                            reason: reason,
                            result: result,
                            showToast: true,
                            allowUploadPrompt: false
                        )
                    }
                    reasonPhotoID = nil
                }
            }
        }
    }

    private func starRatingControl(result: PhotoResult) -> some View {
        let rating = feedbackSaved[result.id]?.starRating ?? 0
        let isSaving = savingFeedbackIDs.contains(result.id)
        let savedReason = feedbackReasons[result.id] ?? ""

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        saveStarRating(star, reason: savedReason, result: result)
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(star <= rating ? ratingTint(rating) : .white.opacity(0.32))
                            .frame(width: 42, height: 42)
                            .background(star == rating ? ratingTint(rating).opacity(0.12) : Color.white.opacity(0.04))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(star == rating ? ratingTint(rating).opacity(0.26) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .disabled(isSaving)
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                }
            }

            HStack(spacing: 6) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.72)
                        .tint(ratingTint(max(rating, 3)))
                }
                Text(rating == 0 ? "Rate this photo" : ratingLabel(rating))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rating == 0 ? .white.opacity(0.45) : ratingTint(rating).opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Text(rating == 0
                 ? "Stars organize this batch and tune future picks on-device."
                 : "Saved as a light preference signal until more ratings confirm the pattern.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            if rating > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Optional details")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.horizontal, 2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(quickReasons(for: rating), id: \.self) { reason in
                                let isSelected = selectedQuickReasons(from: savedReason, allowed: quickReasons(for: rating)).contains(reason)
                                Button {
                                    toggleQuickReason(reason, result: result)
                                } label: {
                                    HStack(spacing: 4) {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        Text(reason)
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .foregroundStyle(isSelected ? .black : .white.opacity(0.62))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? ratingTint(rating) : Color.white.opacity(0.05))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(isSelected ? ratingTint(rating).opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                                }
                                .disabled(isSaving)
                                .accessibilityLabel(reason)
                                .accessibilityHint(isSelected ? "Remove this detail from the rating" : "Add this detail to the rating")
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

                Button {
                    reasonPhotoID = result.id
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: savedReason.isEmpty ? "plus.bubble" : "pencil")
                            .font(.caption2.weight(.bold))
                        Text(savedReason.isEmpty ? "Add note" : "Edit note")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .disabled(isSaving)
                .accessibilityHint("Add optional context for this star rating")

                if !savedReason.isEmpty {
                    Text(savedReason)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.vesperCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.vesperBorder, lineWidth: 1))
    }

    private func comparisonInsightCard(_ insight: String) -> some View {
        let title = insight.hasPrefix("This ranked ahead") || insight.hasPrefix("Nearby frames were close")
            ? "Why this beat nearby shots"
            : "Nearby comparison"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.vesperAccent)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
            }

            Text(insight)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func comparisonInsight(for result: PhotoResult) -> String? {
        let note = result.batchComparisonNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty || result.batchRelativeScore != 0.5 else { return nil }

        if note == "Best frame among similar shots" || result.batchRelativeScore >= 0.82 {
            return "This ranked ahead of nearby frames because \(naturalList(comparisonStrengths(for: result)))."
        }

        if note.hasPrefix("A similar frame") {
            return "\(note). If you still prefer this version, a high star rating teaches Vesper that your taste beats the default comparison."
        }

        return "Nearby frames were close. This one currently has the stronger overall mix of \(naturalList(comparisonStrengths(for: result)))."
    }

    private func comparisonStrengths(for result: PhotoResult) -> [String] {
        var strengths: [String] = []
        if result.qualityScore >= 0.62 { strengths.append("sharpness") }
        if result.exposureScore >= 0.58 { strengths.append("lighting") }
        if result.compositionScore >= 0.58 { strengths.append("composition") }
        if result.hasFace {
            if result.eyeState == .open && result.eyeOpenConfidence >= 0.70 {
                strengths.append("clear eyes")
            } else if result.eyeState == .unknown && result.eyeOcclusionScore > 0.45 {
                strengths.append("less certain but not clearly closed eyes")
            }
            if result.eyeSymmetryScore >= 0.68 { strengths.append("balanced eyes") }
            if result.genuineSmileScore >= 0.55 { strengths.append("expression") }
            if abs(result.faceYaw) < 0.32 { strengths.append("face angle") }
        }
        if (result.referenceScore ?? 0) >= 0.55 { strengths.append("style match") }
        if result.batchRelativeScore >= 0.70 { strengths.append("same-moment comparison") }
        if strengths.isEmpty { strengths.append("technical quality") }
        return Array(strengths.prefix(3))
    }

    private func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return "overall quality"
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return "\(items.dropLast().joined(separator: ", ")), and \(items.last ?? "")"
        }
    }

    private func ratingTint(_ rating: Int) -> Color {
        switch rating {
        case 5: return .green
        case 4: return Color.vesperAccent
        case 3: return .orange
        default: return .red
        }
    }

    private func ratingLabel(_ rating: Int) -> String {
        switch rating {
        case 5: return "Highly preferred"
        case 4: return "Strong pick"
        case 3: return "Backup option"
        case 2: return "Weak backup"
        default: return "Not a fit"
        }
    }

    private func quickReasons(for rating: Int) -> [String] {
        switch rating {
        case 5:
            return ["Great expression", "Good angle", "Good lighting", "Matches my style"]
        case 4:
            return ["Good expression", "Good angle", "Clear photo", "Matches my style"]
        case 3:
            return ["Usable", "Backup", "Mixed expression", "Not the best angle"]
        case 2:
            return ["Awkward expression", "Bad angle", "Poor lighting", "Background"]
        default:
            return ["Blurry", "Eyes", "Bad angle", "Not my style"]
        }
    }

    private func selectedQuickReasons(from reason: String, allowed: [String]) -> Set<String> {
        let parts = reason
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Set(parts.filter { allowed.contains($0) })
    }

    private func customReasonText(from reason: String, excluding quickReasons: [String]) -> String {
        reason
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !quickReasons.contains($0) }
            .joined(separator: ", ")
    }

    private func toggleQuickReason(_ reason: String, result: PhotoResult) {
        guard let rating = feedbackSaved[result.id]?.starRating,
              !savingFeedbackIDs.contains(result.id) else { return }

        let suggestions = quickReasons(for: rating)
        let currentReason = feedbackReasons[result.id] ?? ""
        var selected = selectedQuickReasons(from: currentReason, allowed: suggestions)
        if selected.contains(reason) {
            selected.remove(reason)
        } else {
            selected.insert(reason)
        }

        let combined = FeedbackReasonBuilder.combinedReason(
            suggestions: suggestions,
            selectedReasons: selected,
            customText: customReasonText(from: currentReason, excluding: suggestions)
        )
        saveStarRating(rating, reason: combined, result: result, showToast: true, allowUploadPrompt: false)
    }

    private func showLearningMessage(_ text: String) {
        learningToastText = text
        withAnimation(.spring(response: 0.35)) { showLearningToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastVisibleSeconds) {
            withAnimation(.easeOut(duration: 0.4)) { showLearningToast = false }
        }
    }

    private func saveStarRating(_ starRating: Int, reason: String = "", result: PhotoResult, showToast: Bool = true, allowUploadPrompt: Bool = true) {
        guard !savingFeedbackIDs.contains(result.id) else { return }

        pendingFeedbackUploadTasks[result.id]?.cancel()
        pendingFeedbackUploadTasks[result.id] = nil
        let rating = min(max(starRating, 1), 5)
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let liked = rating >= 4
        let isNeutral = rating == 3
        let feedbackStyle: UINotificationFeedbackGenerator.FeedbackType = liked ? .success : (isNeutral ? .warning : .error)
        UINotificationFeedbackGenerator().notificationOccurred(feedbackStyle)

        if showToast {
            showLearningMessage("Rating saved")
        }

        let index = photos.firstIndex { $0.id == result.id } ?? currentIndex
        let previousImage = index > 0 ? photos[index - 1].image : nil
        let previousState = feedbackSaved[result.id]
        let previousRecord = feedbackRecords[result.id]
        let previousReason = feedbackReasons[result.id]
        let isCorrection = previousState != nil
        feedbackSaved[result.id] = .rated(rating)
        savingFeedbackIDs.insert(result.id)

        Task {
            let imageEmb: [Float]
            if let embedder = CLIPEmbedder.shared,
               let embedding = await embedder.embedAsync(image: result.image) {
                imageEmb = embedding
            } else {
                imageEmb = []
            }

            let reasonEmb: [Float]
            if !cleanReason.isEmpty,
               let textEmbedder = CLIPTextEmbedder.shared,
               let embedding = await textEmbedder.embedAsync(prompt: cleanReason) {
                reasonEmb = embedding
            } else {
                reasonEmb = []
            }

            // Feature 7: contrastive context — embed the photo seen immediately before this one.
            let contrastEmb: [Float]
            if let previousImage,
               let embedder = CLIPEmbedder.shared,
               let embedding = await embedder.embedAsync(image: previousImage) {
                contrastEmb = embedding
            } else {
                contrastEmb = []
            }

            let feedback = PhotoFeedback(
                liked: liked, isNeutral: isNeutral, reason: cleanReason,
                imageEmbedding: imageEmb, reasonEmbedding: reasonEmb,
                purposeTag: purposeTag,
                qualityScore: result.qualityScore,
                exposureScore: result.exposureScore,
                compositionScore: result.compositionScore,
                genuineSmileScore: result.genuineSmileScore,
                contrastEmbedding: contrastEmb,
                faceYaw: result.faceYaw,
                eyeOpenConfidence: result.eyeOpenConfidence,
                colorHarmonyScore: result.colorHarmonyScore,
                referenceScore: result.referenceScore ?? 0.5,
                userFaceIdentified: result.userFaceIdentified,
                starRating: rating
            )
            if let previousRecord {
                modelContext.delete(previousRecord)
            }
            modelContext.insert(feedback)
            var didSave = false
            do {
                try modelContext.save()
                feedbackRecords[result.id] = feedback
                if cleanReason.isEmpty {
                    feedbackReasons.removeValue(forKey: result.id)
                } else {
                    feedbackReasons[result.id] = cleanReason
                }
                didSave = true
                onFeedbackChange(result.id, .rated(rating))
            } catch {
                modelContext.rollback()
                feedbackSaved[result.id] = previousState
                feedbackRecords[result.id] = previousRecord
                feedbackReasons[result.id] = previousReason
                resultsLogger.error("Save photo feedback failed: \(error.localizedDescription, privacy: .private)")
            }
            savingFeedbackIDs.remove(result.id)

            guard didSave else { return }
            addToRatingAlbumIfPossible(result: result, rating: rating)

            if allowUploadPrompt {
                if hasAnsweredPhotoShare, photoShareOptIn {
                    queueFeedbackUpload(photoID: result.id, starRating: rating, reason: cleanReason, result: result,
                                        thumbnail: result.image)
                } else if !isCorrection {
                    pendingFeedbackRating = rating
                    pendingFeedbackReason = cleanReason
                    pendingFeedbackPhotoID = result.id
                    showPhotoSharePrompt = !hasAnsweredPhotoShare
                }
            }
        }
    }

    private func undoFeedback(result: PhotoResult) {
        guard !savingFeedbackIDs.contains(result.id),
              feedbackSaved[result.id] != nil else { return }

        pendingFeedbackUploadTasks[result.id]?.cancel()
        pendingFeedbackUploadTasks[result.id] = nil
        if pendingFeedbackPhotoID == result.id {
            showPhotoSharePrompt = false
            pendingFeedbackReason = ""
            pendingFeedbackPhotoID = nil
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previousState = feedbackSaved[result.id]
        let previousRecord = feedbackRecords[result.id]
        let previousReason = feedbackReasons[result.id]
        feedbackSaved[result.id] = nil
        feedbackRecords[result.id] = nil
        feedbackReasons.removeValue(forKey: result.id)
        savingFeedbackIDs.insert(result.id)

        Task {
            if let previousRecord {
                modelContext.delete(previousRecord)
            }
            do {
                try modelContext.save()
                onFeedbackChange(result.id, nil)
                showLearningMessage("Feedback undone")
            } catch {
                modelContext.rollback()
                feedbackSaved[result.id] = previousState
                feedbackRecords[result.id] = previousRecord
                feedbackReasons[result.id] = previousReason
                resultsLogger.error("Undo photo feedback failed: \(error.localizedDescription, privacy: .private)")
            }
            savingFeedbackIDs.remove(result.id)
        }
    }

    private func queueFeedbackUpload(photoID: UUID, starRating: Int, reason: String, result: PhotoResult, thumbnail: UIImage?) {
        pendingFeedbackUploadTasks[photoID]?.cancel()
        pendingFeedbackUploadTasks[photoID] = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard feedbackSaved[photoID] != nil else { return }
                uploadFeedback(starRating: starRating, reason: reason, result: result, thumbnail: thumbnail)
                pendingFeedbackUploadTasks[photoID] = nil
            }
        }
    }

    private func uploadFeedback(starRating: Int, reason: String, result: PhotoResult, thumbnail: UIImage?) {
        var thumb: UIImage? = nil
        if let t = thumbnail {
            thumb = resized(t, to: 200)
        }
        FeedbackUploadService.shared.upload(
            liked: starRating >= 4,
            starRating: starRating,
            reason: reason,
            category: result.category,
            aesthetic: result.aesthetic,
            promptText: result.promptText,
            isPromptMode: result.isPromptMode,
            qualityScore: result.qualityScore,
            promptScore: result.promptScore,
            referenceScore: result.referenceScore,
            feedbackScore: result.feedbackScore,
            photoThumbnail: thumb
        )
    }

    private func resized(_ image: UIImage, to maxDim: CGFloat) -> UIImage {
        let scale = maxDim / max(image.size.width, image.size.height)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func toggleFavorite(result: PhotoResult) {
        let assetId = result.assetIdentifier
        guard !assetId.isEmpty else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            performFavoriteToggle(assetId: assetId)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self.performFavoriteToggle(assetId: assetId)
                    } else {
                        self.showPhotoAccessAlert = true
                    }
                }
            }
        default:
            showPhotoAccessAlert = true
        }
    }

    private func performFavoriteToggle(assetId: String) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { return }

        let alreadyFav = asset.isFavorite
        // Optimistic UI update — flip immediately, revert if Photos rejects
        DispatchQueue.main.async {
            if alreadyFav { favoritedAssetIds.remove(assetId) } else { favoritedAssetIds.insert(assetId) }
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = !alreadyFav
        } completionHandler: { success, _ in
            DispatchQueue.main.async {
                if success {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if !alreadyFav {
                        withAnimation(.spring(response: 0.35)) { showFavoritedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastVisibleSeconds) {
                            withAnimation(.easeOut(duration: 0.4)) { showFavoritedToast = false }
                        }
                    }
                } else {
                    // Revert optimistic update on failure
                    if alreadyFav { favoritedAssetIds.insert(assetId) } else { favoritedAssetIds.remove(assetId) }
                }
            }
        }
    }

    private func removeFromResults(at index: Int) {
        onDelete(index)
        if index >= photos.count - 1 && index > 0 { currentIndex -= 1 }
        if photos.count <= 1 { onDismiss() }
    }

    private func deleteFromLibrary(at index: Int) {
        guard index < photos.count else { return }
        let result = photos[index]
        let assetId = result.assetIdentifier
        guard !assetId.isEmpty else {
            showPhotoIdentifierUnavailableAlert = true
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else {
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    DispatchQueue.main.async {
                        if newStatus.vesperCanMutateSelectedAssets {
                            self.deleteFromLibrary(at: index)
                        } else {
                            self.showPhotoAccessAlert = true
                        }
                    }
                }
            } else {
                showPhotoAccessAlert = true
            }
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        } completionHandler: { success, _ in
            DispatchQueue.main.async {
                if success {
                    saveStarRating(1, reason: "Deleted from library", result: result, showToast: false, allowUploadPrompt: false)
                    removeFromResults(at: index)
                }
            }
        }
    }

    private func addToRatingAlbumIfPossible(result: PhotoResult, rating: Int) {
        guard autoCreateRatingAlbums else { return }
        let assetId = result.assetIdentifier
        guard !assetId.isEmpty else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            performRatingAlbumUpdate(assetId: assetId, rating: rating)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus.vesperCanMutateSelectedAssets {
                        self.performRatingAlbumUpdate(assetId: assetId, rating: rating)
                    } else {
                        self.showPhotoAccessAlert = true
                    }
                }
            }
        default:
            showPhotoAccessAlert = true
        }
    }

    private func performRatingAlbumUpdate(assetId: String, rating: Int) {
        let normalizedRating = min(max(rating, 1), 5)
        let targetTitle = ratingAlbumTitle(normalizedRating)
        let albums = existingRatingAlbums()
        let targetAlbum = albums[normalizedRating]
        let targetAlreadyContainsAsset = targetAlbum.map { ratingAlbum($0, containsAssetID: assetId) } ?? false

        PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
            guard let asset = assets.firstObject else { return }
            let assetArray = [asset] as NSArray

            for (albumRating, album) in albums where albumRating != normalizedRating {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(assetArray)
            }

            if let targetAlbum {
                if !targetAlreadyContainsAsset {
                    PHAssetCollectionChangeRequest(for: targetAlbum)?.addAssets(assetArray)
                }
            } else {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: targetTitle)
                request.addAssets(assetArray)
            }
        } completionHandler: { success, error in
            if !success, let error {
                resultsLogger.error("Rating album update failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func existingRatingAlbums() -> [Int: PHAssetCollection] {
        var albums: [Int: PHAssetCollection] = [:]
        for rating in 1...5 {
            if let album = fetchAlbum(named: ratingAlbumTitle(rating)) {
                albums[rating] = album
            }
        }
        return albums
    }

    private func fetchAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }

    private func ratingAlbum(_ album: PHAssetCollection, containsAssetID assetId: String) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier = %@", assetId)
        return PHAsset.fetchAssets(in: album, options: options).firstObject != nil
    }

    private func ratingAlbumTitle(_ rating: Int) -> String {
        "Vesper - \(rating) Star\(rating == 1 ? "" : "s")"
    }
}

// MARK: - Rating reason sheet

enum FeedbackReasonBuilder {
    static func combinedReason(suggestions: [String], selectedReasons: Set<String>, customText: String) -> String {
        let selected = suggestions.filter { selectedReasons.contains($0) }
        let custom = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = custom.isEmpty || selected.contains(where: { $0.caseInsensitiveCompare(custom) == .orderedSame })
            ? selected
            : selected + [custom]
        return parts.joined(separator: ", ")
    }
}

struct RatingReasonSheet: View {
    let onSubmit: (String) -> Void

    @State private var reasonText = ""
    @State private var selectedReasons: Set<String> = []
    @FocusState private var isFocused: Bool

    private let suggestions = [
        "Great expression", "Awkward expression", "Good angle", "Bad angle",
        "Good lighting", "Poor lighting", "Blurry", "Background",
        "Matches my style", "Not my style", "Eyes", "Pose"
    ]

    init(initialText: String = "", onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        _reasonText = State(initialValue: initialText)
    }

    private var combinedReason: String {
        FeedbackReasonBuilder.combinedReason(
            suggestions: suggestions,
            selectedReasons: selectedReasons,
            customText: reasonText
        )
    }

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Add rating notes")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Optional notes help Vesper understand this rating.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 32)
                .padding(.horizontal, 24)

                TextField("Add a quick note...", text: $reasonText, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.body)
                    .foregroundStyle(.white)
                    .tint(Color.vesperAccent)
                    .padding()
                    .background(Color.vesperCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isFocused ? Color.vesperAccent.opacity(0.4) : Color.vesperBorder, lineWidth: 1))
                    .focused($isFocused)
                    .padding(.horizontal, 24)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            let isSelected = selectedReasons.contains(s)
                            Button {
                                if isSelected {
                                    selectedReasons.remove(s)
                                } else {
                                    selectedReasons.insert(s)
                                }
                                isFocused = false
                            } label: {
                                HStack(spacing: 5) {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text(s)
                                        .font(.caption)
                                }
                                .foregroundStyle(isSelected ? .black : .white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.vesperAccent : Color.vesperCard)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(isSelected ? Color.vesperAccent.opacity(0.35) : Color.vesperBorder, lineWidth: 1))
                            }
                            .accessibilityLabel(s)
                            .accessibilityHint(isSelected ? "Remove this feedback reason" : "Add this feedback reason")
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        isFocused = false
                        onSubmit(combinedReason)
                    } label: {
                        Text("Save Notes")
                            .vesperPrimaryButton()
                    }

                    Button {
                        onSubmit("")
                    } label: {
                        Text("Clear Notes")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .onTapGesture { isFocused = false }
    }
}

// MARK: - Photo share consent

struct PhotoShareConsentSheet: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.vesperAccent.opacity(0.08))
                        .frame(width: 100, height: 100)
                        .blur(radius: 20)
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Color.vesperAccent.opacity(0.8))
                }

                VStack(spacing: 10) {
                    Text("Help improve Vesper?")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Share optional product feedback: ratings, notes, prompts, scores, and a small low-resolution thumbnail. Your local scoring still runs on-device.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.vesperAccent.opacity(0.6))
                    Text("Optional · Private by default · Never sold")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        onAnswer(true)
                    } label: {
                        Text("Sure, help improve Vesper")
                            .vesperPrimaryButton()
                    }

                    Button {
                        onAnswer(false)
                    } label: {
                        Text("No thanks, keep feedback local")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Share sheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ResultsView(topPicks: [], runnerUps: [])
}
