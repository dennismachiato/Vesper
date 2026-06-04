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
    @State private var showRunnerUps = false
    @State private var showDeleteCandidates = false
    @State private var showSimilars = false
    @State private var galleryStartIndex: Int? = nil
    @State private var galleryPool: GalleryPool = .topPicks
    @State private var showAlbumSavedToast = false
    @State private var showPromotedToast = false
    @State private var showRerankedToast = false
    @State private var sessionFeedback: [UUID: GalleryView.FeedbackState] = [:]
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteAllConfirm = false
    @State private var showPhotoLibraryAccessAlert = false
    @State private var isMultiSelectingDeletes = false
    @State private var selectedDeleteIndices: Set<Int> = []
    @State private var showMultiDeleteConfirm = false
    @State private var isMultiSelectingSimilars = false
    @State private var selectedSimilarIndices: Set<Int> = []
    @State private var showMultiSimilarDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @AppStorage("completedBatchCount") private var completedBatchCount = 0
    // Ensures `completedBatchCount` only increments once per ResultsView
    // instance — a re-appear from a pushed detail view otherwise inflates the
    // count and would trigger the review prompt too early.
    @State private var didCountThisBatch = false

    enum GalleryPool { case topPicks, runnerUps, deleteCandidates, similars }

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
                            Text("Tap a photo to view · Use Like, Meh, or Dislike to train the AI")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            saveTopPicksToAlbum()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.caption.bold())
                                Text("Save All")
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
                                Text(showAlbumSavedToast ? "Saved to Photos album" : "Results updated from your feedback")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .offset(y: 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

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
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeInOut(duration: 0.2)) { showRunnerUps.toggle() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Worth Reviewing")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                    Text("Good alternates the AI did not rank as top picks — tap \(Image(systemName: "plus.circle.fill")) to promote")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.4))
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
                                        // Promote button: moves this photo to top picks and teaches the AI
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

                            if showPromotedToast {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.vesperAccent)
                                    Text("Added to top picks · AI will learn from this")
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

                    // Delete candidates section
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
                                            Text("Review for Deletion")
                                                .font(.title2.bold())
                                                .foregroundStyle(.white)
                                        }
                                        Text("Weakest cleanup picks, blurry shots, or closed eyes")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.4))
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
                                            Text("Delete All")
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
                                "Delete \(deleteCandidates.count) photo\(deleteCandidates.count == 1 ? "" : "s") from your iPhone?",
                                isPresented: $showDeleteAllConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Delete from Library", role: .destructive) { deleteAllDeleteCandidates() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This permanently deletes these photos. It cannot be undone.")
                            }
                            .confirmationDialog(
                                "Delete \(selectedDeleteIndices.count) selected photo\(selectedDeleteIndices.count == 1 ? "" : "s") from your iPhone?",
                                isPresented: $showMultiDeleteConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Delete from Library", role: .destructive) { deleteSelectedDeleteCandidates() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This permanently deletes these photos. It cannot be undone.")
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
                                            Text("Delete \(selectedDeleteIndices.count) Selected")
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
                                        Text("Burst shots and near-identical frames")
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
                                "Delete \(selectedSimilarIndices.count) selected photo\(selectedSimilarIndices.count == 1 ? "" : "s") from your iPhone?",
                                isPresented: $showMultiSimilarDeleteConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Delete from Library", role: .destructive) { deleteSelectedSimilars() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This permanently deletes these photos. It cannot be undone.")
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
                                            Text("Delete \(selectedSimilarIndices.count) Selected")
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
        .fullScreenCover(isPresented: Binding(
            get: { galleryStartIndex != nil },
            set: { if !$0 { galleryStartIndex = nil } }
        )) {
            let photos: [PhotoResult] = {
                switch galleryPool {
                case .topPicks:         return topPicks
                case .runnerUps:        return runnerUps
                case .deleteCandidates: return deleteCandidates
                case .similars:         return similars
                }
            }()
            GalleryView(
                photos: photos,
                startIndex: galleryStartIndex ?? 0,
                showReasoning: galleryPool == .topPicks || galleryPool == .runnerUps,
                purposeTag: purposeTag,
                allPhotoScores: topPicks + runnerUps,
                onDelete: { index in
                    switch galleryPool {
                    case .topPicks:         topPicks.remove(at: index)
                    case .runnerUps:        runnerUps.remove(at: index)
                    case .deleteCandidates: deleteCandidates.remove(at: index)
                    case .similars:         similars.remove(at: index)
                    }
                },
                onFeedbackChange: { photoID, state in
                    applyLiveFeedback(photoID: photoID, state: state)
                }
            ) {
                galleryStartIndex = nil
            }
        }
    }

    private func openGallery(index: Int, isTopPicks: Bool) {
        galleryPool = isTopPicks ? .topPicks : .runnerUps
        galleryStartIndex = index
    }

    private func applyLiveFeedback(photoID: UUID, state: GalleryView.FeedbackState?) {
        if let state {
            sessionFeedback[photoID] = state
        } else {
            sessionFeedback.removeValue(forKey: photoID)
        }

        guard topPicks.contains(where: { $0.id == photoID }) ||
              runnerUps.contains(where: { $0.id == photoID }) else { return }

        rerankTopAndReviewPools()
        withAnimation(.spring(response: 0.35)) { showRerankedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.35)) { showRerankedToast = false }
        }
    }

    private func rerankTopAndReviewPools() {
        let targetTopCount = max(1, topPicks.count)
        let combined = topPicks + runnerUps
        guard combined.count > 1 else { return }

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
                        withAnimation(.spring(response: 0.4)) { showAlbumSavedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { showAlbumSavedToast = false }
                        }
                    }
                }
            }
        }
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

        let assetIds = deleteCandidates.compactMap { $0.assetIdentifier.isEmpty ? nil : $0.assetIdentifier }
        if assetIds.isEmpty { deleteCandidates = []; return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async { if success { deleteCandidates = [] } }
        }
    }

    private func deleteSelectedDeleteCandidates() {
        let indices = selectedDeleteIndices.sorted().reversed()
        let assetIds = indices.compactMap { deleteCandidates[$0].assetIdentifier.isEmpty ? nil : deleteCandidates[$0].assetIdentifier }
        let localIndices = Array(indices)

        if assetIds.isEmpty {
            for i in localIndices { deleteCandidates.remove(at: i) }
            selectedDeleteIndices = []
            isMultiSelectingDeletes = false
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else { showPhotoLibraryAccessAlert = true; return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    for i in localIndices { deleteCandidates.remove(at: i) }
                    selectedDeleteIndices = []
                    isMultiSelectingDeletes = false
                }
            }
        }
    }

    private func deleteSelectedSimilars() {
        let indices = selectedSimilarIndices.sorted().reversed()
        let assetIds = indices.compactMap { similars[$0].assetIdentifier.isEmpty ? nil : similars[$0].assetIdentifier }
        let localIndices = Array(indices)

        if assetIds.isEmpty {
            for i in localIndices { similars.remove(at: i) }
            selectedSimilarIndices = []
            isMultiSelectingSimilars = false
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status.vesperCanMutateSelectedAssets else { showPhotoLibraryAccessAlert = true; return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    for i in localIndices { similars.remove(at: i) }
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

        // Save positive feedback so the AI learns the user preferred this photo
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
    @State private var feedbackSaved: [Int: FeedbackState] = [:]
    @State private var feedbackRecords: [Int: PhotoFeedback] = [:]
    @State private var savingFeedbackIndices: Set<Int> = []
    @State private var showDeleteConfirm = false
    @State private var showDeleteFromLibraryConfirm = false
    @State private var showPhotoSharePrompt = false
    @State private var showShareSheet = false
    @State private var favoritedIndices: Set<Int> = []
    @State private var showPhotoAccessAlert = false
    @State private var showLearningToast = false
    @State private var learningToastText = "Vesper is learning your taste"
    @State private var showFavoritedToast = false
    @State private var pendingFeedbackUploadTasks: [Int: Task<Void, Never>] = [:]
    /// How long in-screen toasts stay visible before auto-dismissing.
    /// Tuned to ~read-one-line-of-text; matches the spring/ease timings below.
    private static let toastVisibleSeconds: Double = 2.2
    @State private var dragOffset: CGFloat = 0
    @State private var photoScale: CGFloat = 1.0
    @State private var photoLastScale: CGFloat = 1.0
    @State private var pendingFeedbackRating = 5
    @State private var pendingFeedbackReason = ""
    @State private var pendingFeedbackIndex = 0
    @AppStorage("hasAnsweredPhotoShare") private var hasAnsweredPhotoShare = false
    @AppStorage("photoShareOptIn") private var photoShareOptIn = false
    @Environment(\.modelContext) private var modelContext

    enum FeedbackState: Equatable {
        case liked
        case neutral
        case disliked
        case rated(Int)

        var starRating: Int {
            switch self {
            case .liked: return 5
            case .neutral: return 3
            case .disliked: return 1
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
        guard !photos.isEmpty, currentIndex < photos.count else { return nil }
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
                        ForEach(Array(photos.enumerated()), id: \.offset) { index, result in
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

                    starRatingControl(index: currentIndex)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    if feedbackSaved[currentIndex] != nil {
                        Button {
                            undoFeedback(index: currentIndex)
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
                        .disabled(savingFeedbackIndices.contains(currentIndex))
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    // Favorite in Photos app
                    let isFav = favoritedIndices.contains(currentIndex)
                    Button {
                        toggleFavorite(at: currentIndex)
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
                            Text("This permanently deletes the photo from your iPhone. It cannot be undone.")
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
                    HStack(spacing: 8) {
                        Image(systemName: "brain.fill")
                            .font(.caption)
                            .foregroundStyle(Color.vesperAccent)
                        Text(learningToastText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
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
            favoritedIndices = Set(photos.indices.filter { i in
                favIds.contains(photos[i].assetIdentifier)
            })
        }
        .alert("Photos Access Required", isPresented: $showPhotoAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To favorite or delete photos, allow Vesper access to the selected photos or full access in Settings.")
        }
        .sheet(isPresented: $showPhotoSharePrompt) {
            PhotoShareConsentSheet { optIn in
                hasAnsweredPhotoShare = true
                photoShareOptIn = optIn
                let result = pendingFeedbackIndex < photos.count ? photos[pendingFeedbackIndex] : nil
                if optIn, let result {
                    queueFeedbackUpload(
                        index: pendingFeedbackIndex,
                        starRating: pendingFeedbackRating,
                        reason: pendingFeedbackReason,
                        result: result,
                        thumbnail: result.image
                    )
                }
                showPhotoSharePrompt = false
            }
        }
    }

    private func starRatingControl(index: Int) -> some View {
        let rating = feedbackSaved[index]?.starRating ?? 0
        let isSaving = savingFeedbackIndices.contains(index)

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        saveStarRating(star, index: index)
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
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.vesperCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.vesperBorder, lineWidth: 1))
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
        case 4: return "Decent pick"
        case 3: return "OK"
        case 2: return "Weak photo"
        default: return "Not ideal"
        }
    }

    private func showLearningMessage(_ text: String) {
        learningToastText = text
        withAnimation(.spring(response: 0.35)) { showLearningToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastVisibleSeconds) {
            withAnimation(.easeOut(duration: 0.4)) { showLearningToast = false }
        }
    }

    private func saveStarRating(_ starRating: Int, reason: String = "", index: Int, showToast: Bool = true, allowUploadPrompt: Bool = true) {
        guard index < photos.count, !savingFeedbackIndices.contains(index) else { return }

        pendingFeedbackUploadTasks[index]?.cancel()
        pendingFeedbackUploadTasks[index] = nil
        let rating = min(max(starRating, 1), 5)
        let liked = rating >= 4
        let isNeutral = rating == 3
        let feedbackStyle: UINotificationFeedbackGenerator.FeedbackType = liked ? .success : (isNeutral ? .warning : .error)
        UINotificationFeedbackGenerator().notificationOccurred(feedbackStyle)

        if showToast {
            showLearningMessage("Vesper is learning your taste")
        }

        let result = photos[index]
        let previousImage = index > 0 ? photos[index - 1].image : nil
        let previousState = feedbackSaved[index]
        let previousRecord = feedbackRecords[index]
        let isCorrection = previousState != nil
        feedbackSaved[index] = .rated(rating)
        savingFeedbackIndices.insert(index)

        Task {
            let imageEmb: [Float]
            if let embedder = CLIPEmbedder.shared,
               let embedding = await embedder.embedAsync(image: result.image) {
                imageEmb = embedding
            } else {
                imageEmb = []
            }

            let reasonEmb: [Float]
            if !reason.isEmpty,
               let textEmbedder = CLIPTextEmbedder.shared,
               let embedding = await textEmbedder.embedAsync(prompt: reason) {
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
                liked: liked, isNeutral: isNeutral, reason: reason,
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
                feedbackRecords[index] = feedback
                didSave = true
                onFeedbackChange(result.id, .rated(rating))
            } catch {
                modelContext.rollback()
                feedbackSaved[index] = previousState
                feedbackRecords[index] = previousRecord
                resultsLogger.error("Save photo feedback failed: \(error.localizedDescription, privacy: .private)")
            }
            savingFeedbackIndices.remove(index)

            guard didSave else { return }

            if allowUploadPrompt {
                if hasAnsweredPhotoShare, photoShareOptIn {
                    queueFeedbackUpload(index: index, starRating: rating, reason: reason, result: result,
                                        thumbnail: result.image)
                } else if !isCorrection {
                    pendingFeedbackRating = rating
                    pendingFeedbackReason = reason
                    pendingFeedbackIndex = index
                    showPhotoSharePrompt = !hasAnsweredPhotoShare
                }
            }
        }
    }

    private func undoFeedback(index: Int) {
        guard index < photos.count, !savingFeedbackIndices.contains(index),
              feedbackSaved[index] != nil else { return }

        pendingFeedbackUploadTasks[index]?.cancel()
        pendingFeedbackUploadTasks[index] = nil
        if pendingFeedbackIndex == index {
            showPhotoSharePrompt = false
            pendingFeedbackReason = ""
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previousState = feedbackSaved[index]
        let previousRecord = feedbackRecords[index]
        feedbackSaved[index] = nil
        feedbackRecords[index] = nil
        savingFeedbackIndices.insert(index)

        Task {
            if let previousRecord {
                modelContext.delete(previousRecord)
            }
            do {
                try modelContext.save()
                onFeedbackChange(photos[index].id, nil)
                showLearningMessage("Feedback undone")
            } catch {
                modelContext.rollback()
                feedbackSaved[index] = previousState
                feedbackRecords[index] = previousRecord
                resultsLogger.error("Undo photo feedback failed: \(error.localizedDescription, privacy: .private)")
            }
            savingFeedbackIndices.remove(index)
        }
    }

    private func queueFeedbackUpload(index: Int, starRating: Int, reason: String, result: PhotoResult, thumbnail: UIImage?) {
        pendingFeedbackUploadTasks[index]?.cancel()
        pendingFeedbackUploadTasks[index] = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard feedbackSaved[index] != nil else { return }
                uploadFeedback(starRating: starRating, reason: reason, result: result, thumbnail: thumbnail)
                pendingFeedbackUploadTasks[index] = nil
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

    private func toggleFavorite(at index: Int) {
        guard index < photos.count else { return }
        let assetId = photos[index].assetIdentifier
        guard !assetId.isEmpty else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            performFavoriteToggle(assetId: assetId, index: index)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self.performFavoriteToggle(assetId: assetId, index: index)
                    } else {
                        self.showPhotoAccessAlert = true
                    }
                }
            }
        default:
            showPhotoAccessAlert = true
        }
    }

    private func performFavoriteToggle(assetId: String, index: Int) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { return }

        let alreadyFav = asset.isFavorite
        // Optimistic UI update — flip immediately, revert if Photos rejects
        DispatchQueue.main.async {
            if alreadyFav { favoritedIndices.remove(index) } else { favoritedIndices.insert(index) }
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
                    if alreadyFav { favoritedIndices.insert(index) } else { favoritedIndices.remove(index) }
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
        let assetId = photos[index].assetIdentifier
        saveStarRating(1, reason: "Deleted from library", index: index, showToast: false, allowUploadPrompt: false)
        guard !assetId.isEmpty else {
            // No identifier available — fall back to remove from results only
            removeFromResults(at: index)
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
                    removeFromResults(at: index)
                }
            }
        }
    }
}

// MARK: - Dislike reason sheet

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

struct DislikeReasonSheet: View {
    let onSubmit: (String) -> Void

    @State private var reasonText = ""
    @State private var selectedReasons: Set<String> = []
    @FocusState private var isFocused: Bool

    private let suggestions = [
        "Eyes closed", "Bad angle", "Blurry", "Expression is off",
        "Lighting is bad", "Looking at camera", "Not the vibe"
    ]

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
                    Text("What didn't you like?")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Vesper will learn from this for next time")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 32)

                TextField("Add more detail...", text: $reasonText, axis: .vertical)
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
                        Text("Submit Feedback")
                            .vesperPrimaryButton()
                    }

                    Button {
                        onSubmit("")
                    } label: {
                        Text("Skip")
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
                    Text("Share anonymous rating details and a small, low-resolution copy of rated photos to help improve Vesper. Your local scoring still runs on-device.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.vesperAccent.opacity(0.6))
                    Text("Optional · Anonymous · Never sold")
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
