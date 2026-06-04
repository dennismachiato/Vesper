//
//  ContentView.swift
//  Vesper

import SwiftUI
import Photos
import PhotosUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var photoService = PhotoLibraryService()
    @State private var showBatchSetup = false
    @State private var showCleanUp = false
    @State private var showAITraining = false
    @State private var showProfile = false
    @State private var showHistory = false
    @State private var showPhotoAccessDenied = false
    @Query(sort: \ReferencePhoto.createdAt) private var referencePhotos: [ReferencePhoto]
    @Query(sort: \BatchHistory.createdAt, order: .reverse) private var recentHistory: [BatchHistory]

    var body: some View {
        NavigationStack {
            ZStack {
                // Ambient glow behind the logo
                Circle()
                    .fill(Color.vesperAccent.opacity(0.07))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(y: -120)

                VStack(spacing: 0) {
                    Spacer()

                    // Logo
                    VStack(spacing: 10) {
                        Text("Vesper")
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(LinearGradient.vesperGold)
                        Text("Rank, rate, and organize your photos")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    Spacer()

                    // Style card — tap to go to profile
                    Button {
                        showProfile = true
                    } label: {
                        HStack(spacing: 14) {
                            if referencePhotos.isEmpty {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                // Show up to 3 reference photo thumbnails stacked
                                // Decoded asynchronously to avoid blocking the main thread
                                ZStack {
                                    ForEach(Array(referencePhotos.prefix(3).enumerated().reversed()), id: \.offset) { index, photo in
                                        AsyncThumbnailView(data: photo.thumbnailData)
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .offset(x: CGFloat(index) * 6)
                                    }
                                }
                                .frame(width: 44 + CGFloat(min(referencePhotos.count, 3) - 1) * 6, height: 44)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(referencePhotos.isEmpty ? "Set up your style" : "Your style profile")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                                Text(referencePhotos.isEmpty
                                     ? "Add reference photos to improve matching"
                                     : "\(referencePhotos.count) reference photo\(referencePhotos.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.45))
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(16)
                        .vesperCard(cornerRadius: 16)
                        .padding(.horizontal, 24)
                    }

                    Spacer()
                        .frame(height: 20)

                    // Recent history strip
                    if !recentHistory.isEmpty {
                        Button { showHistory = true } label: {
                            HStack(spacing: 12) {
                                // Up to 3 thumbnail stacks
                                HStack(spacing: 3) {
                                    ForEach(Array(recentHistory.prefix(3).enumerated()), id: \.offset) { _, batch in
                                        if let thumb = batch.thumbnails.first {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 36, height: 44)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Recent batches")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                    Text("\(recentHistory.count) batch\(recentHistory.count == 1 ? "" : "es")")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.45))
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(14)
                            .vesperCard(cornerRadius: 14)
                            .padding(.horizontal, 24)
                        }

                        Spacer().frame(height: 16)
                    }

                    // Get Started nudge — shown only on very first use
                    if recentHistory.isEmpty && referencePhotos.isEmpty {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("How it works")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)

                                ForEach([
                                    ("1", "photo.stack", "Pick 10–50 similar photos", "Burst shots, event photos, anything you want to sort through"),
                                    ("2", "sparkles", "Vesper ranks them privately", "Scored by sharpness, faces, expression, and your style on-device"),
                                    ("3", "star.circle", "Rate and sort the batch", "Use 1-5 stars to organize photos and teach Vesper your taste")
                                ], id: \.0) { _, icon, title, subtitle in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: icon)
                                            .font(.body)
                                            .foregroundStyle(Color.vesperAccent)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(title)
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                            Text(subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(.white.opacity(0.45))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .vesperCard(cornerRadius: 14)
                            .padding(.horizontal, 24)

                            Image(systemName: "chevron.down")
                                .font(.caption.bold())
                                .foregroundStyle(Color.vesperAccent.opacity(0.6))
                                .padding(.top, 6)
                        }
                        .padding(.bottom, 8)
                    }

                    // Primary actions
                    VStack(spacing: 12) {
                        Button {
                            Task {
                                if photoService.isDenied { showPhotoAccessDenied = true; return }
                                await photoService.requestPermission()
                                if photoService.isAuthorized { showBatchSetup = true }
                                else if photoService.isDenied { showPhotoAccessDenied = true }
                            }
                        } label: {
                            Text("Sort New Batch")
                                .vesperPrimaryButton()
                        }

                        Button {
                            Task {
                                if photoService.isDenied { showPhotoAccessDenied = true; return }
                                await photoService.requestPermission()
                                if photoService.isAuthorized { showCleanUp = true }
                                else if photoService.isDenied { showPhotoAccessDenied = true }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.subheadline)
                                Text("Full Library Cleanup")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
                        }

                        Button {
                            Task {
                                if photoService.isDenied { showPhotoAccessDenied = true; return }
                                await photoService.requestPermission()
                                if photoService.isAuthorized { showAITraining = true }
                                else if photoService.isDenied { showPhotoAccessDenied = true }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "brain.head.profile")
                                    .font(.subheadline)
                                Text("Test & Teach Vesper")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Color.vesperAccent.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.vesperAccent.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.vesperAccent.opacity(0.18), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 52)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .vesperBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showProfile = true } label: {
                        Image(systemName: "person.circle")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .sheet(isPresented: $showPhotoAccessDenied) {
                PhotoAccessDeniedView()
            }
            .navigationDestination(isPresented: $showBatchSetup) {
                BatchSetupView()
            }
            .navigationDestination(isPresented: $showCleanUp) {
                CleanUpView()
            }
            .navigationDestination(isPresented: $showAITraining) {
                AITrainingView()
            }
            .navigationDestination(isPresented: $showProfile) {
                ProfileView()
            }
            .navigationDestination(isPresented: $showHistory) {
                HistoryView()
            }
        }
    }
}

#Preview {
    HomeView()
}
