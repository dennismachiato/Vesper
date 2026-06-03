//
//  HistoryView.swift
//  Vesper

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \BatchHistory.createdAt, order: .reverse) private var history: [BatchHistory]
    @Environment(\.modelContext) private var modelContext

    // Two-step destructive confirmation: context-menu "Delete" stages a batch,
    // then a .confirmationDialog asks the user before the SwiftData delete fires.
    @State private var batchPendingDelete: BatchHistory?

    var body: some View {
        Group {
            if history.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .vesperBackground()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog(
            "Delete this batch?",
            isPresented: Binding(
                get: { batchPendingDelete != nil },
                set: { if !$0 { batchPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: batchPendingDelete
        ) { batch in
            Button("Delete", role: .destructive) {
                modelContext.delete(batch)
                batchPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { batchPendingDelete = nil }
        } message: { _ in
            Text("This removes the batch from your history. Your original photos in Photos are not affected.")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.vesperAccent.opacity(0.5))
            Text("No batches yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.5))
            Text("Your past results will appear here after your first batch.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(history) { batch in
                    NavigationLink(destination: HistoryDetailView(batch: batch)) {
                        HistoryRowView(batch: batch)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            batchPendingDelete = batch
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Row

struct HistoryRowView: View {
    let batch: BatchHistory

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail strip — up to 4 photos
            HStack(spacing: 3) {
                ForEach(Array(batch.thumbnails.prefix(4).enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 64)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                // Placeholder slots if fewer than 4
                ForEach(0..<max(0, 4 - batch.thumbnails.count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 52, height: 64)
                }
            }

            // Metadata
            VStack(alignment: .leading, spacing: 5) {
                Text(batch.label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !batch.isPromptMode {
                    Text(batch.aesthetic)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }

                HStack(spacing: 6) {
                    Text("\(batch.pickCount) picks · \(batch.totalPhotos) photos")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.25))
                    Text(batch.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(14)
        .vesperCard(cornerRadius: 14)
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
