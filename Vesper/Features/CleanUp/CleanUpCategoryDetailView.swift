//
//  CleanUpCategoryDetailView.swift
//  Vesper
//
//  Shows all photos in a single cleanup category as a scrollable grid.
//  The user can:
//    • Tap a photo to select/deselect it
//    • "Select All" / "Deselect All"
//    • "Delete Selected" — triggers the system PHAsset deletion confirmation
//

import SwiftUI
import Photos

struct CleanUpCategoryDetailView: View {
    let group: CleanUpGroup
    let scanner: LibraryScanner

    @State private var selectedIdentifiers: Set<String> = []
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var deletionError: String? = nil
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 4)

    /// All assets in this group. The user chooses which ones to delete.
    private var allIdentifiers: Set<String> {
        Set(group.assets.map(\.localIdentifier))
    }

    private var selectedCount: Int { selectedIdentifiers.count }

    private var selectedSize: Int64 {
        group.assets
            .filter { selectedIdentifiers.contains($0.localIdentifier) }
            .reduce(Int64(0)) { sum, asset in
                let resources = PHAssetResource.assetResources(for: asset)
                if let r = resources.first, let size = r.value(forKey: "fileSize") as? Int64 {
                    return sum + size
                }
                return sum + Int64(asset.pixelWidth) * Int64(asset.pixelHeight) * 3 / 8
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar bar
            HStack {
                Button(selectedIdentifiers.count == group.count ? "Deselect All" : "Select All") {
                    if selectedIdentifiers.count == group.count {
                        selectedIdentifiers.removeAll()
                    } else {
                        selectedIdentifiers = allIdentifiers
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.vesperAccent)

                Spacer()

                Text("\(selectedCount) selected · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.vesperAccent.opacity(0.75))
                Text("Select only the items you want to delete. Nothing is selected by default.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Photo grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        CleanUpThumbnailView(
                            asset: asset,
                            isSelected: selectedIdentifiers.contains(asset.localIdentifier)
                        )
                        .onTapGesture {
                            toggleSelection(asset.localIdentifier)
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, selectedIdentifiers.isEmpty ? 24 : 100)   // room for bottom bar
            }

            // Bottom delete bar
            if !selectedIdentifiers.isEmpty {
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1))

                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.black)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text(isDeleting ? "Deleting..." : "Delete \(selectedCount) Item\(selectedCount == 1 ? "" : "s")")
                        }
                        .vesperPrimaryButton()
                    }
                    .disabled(isDeleting)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .background(.ultraThinMaterial.opacity(0.8))
            }
        }
        .vesperBackground()
        .navigationTitle(group.category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog(
            "Delete \(selectedCount) item\(selectedCount == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(selectedCount) item\(selectedCount == 1 ? "" : "s") to Recently Deleted. You can recover them for 30 days.")
        }
        .alert("Deletion Failed", isPresented: .init(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    // MARK: - Actions

    private func toggleSelection(_ identifier: String) {
        if selectedIdentifiers.contains(identifier) {
            selectedIdentifiers.remove(identifier)
        } else {
            selectedIdentifiers.insert(identifier)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func performDeletion() async {
        isDeleting = true
        let assetsToDelete = group.assets.filter { selectedIdentifiers.contains($0.localIdentifier) }

        do {
            try await scanner.deleteAssets(assetsToDelete)
            // If successful, dismiss back to the category list
            dismiss()
        } catch {
            deletionError = error.localizedDescription
        }

        isDeleting = false
    }
}

// MARK: - Thumbnail cell

/// Async-loading thumbnail with a selection overlay.
private struct CleanUpThumbnailView: View {
    let asset: PHAsset
    let isSelected: Bool

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .aspectRatio(1, contentMode: .fill)
            }

            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? Color.vesperAccent : .white.opacity(0.5))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.vesperAccent : Color.clear, lineWidth: 2)
        )
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let size = CGSize(width: 200, height: 200)
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let loaded: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { img, info in
                // PHImageManager may call this twice (low-quality + full) — only
                // resume the continuation once.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.resume(returning: img)
                }
            }
        }

        await MainActor.run { image = loaded }
    }
}
