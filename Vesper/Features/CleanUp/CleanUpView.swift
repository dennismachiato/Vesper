//
//  CleanUpView.swift
//  Vesper
//
//  Main view for the library cleanup feature. Shows scanning progress while
//  the LibraryScanner runs, then presents category cards with counts and
//  file sizes once each phase completes. Cards are tappable — they navigate
//  to CleanUpCategoryDetailView for review and deletion.
//

import SwiftUI
import Photos

struct CleanUpView: View {
    @State private var scanner = LibraryScanner()
    @State private var selectedGroup: CleanUpGroup? = nil

    /// Sorted groups — metadata categories first, AI categories last.
    private var sortedGroups: [CleanUpGroup] {
        scanner.groups.values
            .filter { $0.count > 0 }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Scanning indicator
                if scanner.isScanning {
                    scanningSection
                }

                // Summary bar — shown once any results exist
                if !sortedGroups.isEmpty {
                    summaryBar
                }

                // Category cards
                if !sortedGroups.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(sortedGroups) { group in
                            NavigationLink(value: group.category) {
                                categoryCard(group)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Empty state — shown only after scan completes with nothing found
                if scanner.scanComplete && sortedGroups.isEmpty {
                    emptyState
                }

                Spacer(minLength: 60)
            }
            .padding(.top, 16)
        }
        .vesperBackground()
        .navigationTitle("Clean Up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(for: CleanUpCategory.self) { category in
            if let group = scanner.groups[category] {
                CleanUpCategoryDetailView(group: group, scanner: scanner)
            }
        }
        .task {
            if !scanner.isScanning && !scanner.scanComplete {
                await scanner.startScan()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.vesperAccent.opacity(0.08))
                    .frame(width: 72, height: 72)
                    .blur(radius: 16)
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
            }

            Text("Full Library Cleanup")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("Scan your whole library for screenshots, duplicates, and clutter")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Scanning progress

    private var scanningSection: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(scanner.scanProgress))
                .progressViewStyle(.linear)
                .tint(Color.vesperAccent)

            HStack {
                Text(scanner.scanPhase)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Int(scanner.scanProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.vesperAccent.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Summary bar

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.vesperAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(ByteCountFormatter.string(fromByteCount: scanner.totalReclaimableBytes, countStyle: .file)) reclaimable")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text("\(scanner.totalReclaimableCount) items found across \(sortedGroups.count) categories")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(16)
        .vesperCard(cornerRadius: 14)
        .padding(.horizontal, 24)
    }

    // MARK: - Category card

    private func categoryCard(_ group: CleanUpGroup) -> some View {
        HStack(spacing: 14) {
            Image(systemName: group.category.icon)
                .font(.title3)
                .foregroundStyle(Color.vesperAccent)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(group.category.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)

                    if group.isScanning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white.opacity(0.5))
                    }
                }

                Text("\(group.count) item\(group.count == 1 ? "" : "s") · \(group.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(16)
        .vesperCard(cornerRadius: 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.vesperAccent)

            Text("Your library is clean!")
                .font(.headline)
                .foregroundStyle(.white)

            Text("No screenshots, duplicates, or clutter found")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.top, 40)
    }
}

#Preview {
    NavigationStack {
        CleanUpView()
    }
}
