//
//  ProfileView.swift
//  Vesper

import SwiftUI
import SwiftData
import PhotosUI
import OSLog

private let profileLogger = Logger(subsystem: "Vesper", category: "Profile")

private struct LearningInsight: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    init(icon: String, title: String, detail: String, tint: Color) {
        self.id = title
        self.icon = icon
        self.title = title
        self.detail = detail
        self.tint = tint
    }
}

private struct LearningSignalSummary {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let confidence: Double
}

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReferencePhoto.createdAt) private var referencePhotos: [ReferencePhoto]
    @Query(sort: \PhotoFeedback.createdAt, order: .reverse) private var feedbackHistory: [PhotoFeedback]

    @Query(sort: \BatchHistory.createdAt, order: .reverse) private var batchHistory: [BatchHistory]

    @State private var referencePickerItems: [PhotosPickerItem] = []
    @State private var showClearFeedbackConfirm = false
    @State private var isLearning = false
    @State private var learningProgress: Double = 0
    @State private var learningTotal: Int = 0

    // Privacy / data controls
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteAllError = false
    @State private var showExportShare = false
    @State private var exportFileURL: URL?

    private var highRatedCount: Int { feedbackHistory.filter(\.isPositiveSignal).count }
    private var neutralCount: Int { feedbackHistory.filter(\.isNeutralSignal).count }
    private var lowRatedCount: Int { feedbackHistory.filter(\.isNegativeSignal).count }
    private var multiPersonReferenceCount: Int { referencePhotos.filter { $0.faceCount > 1 }.count }
    private var clearSoloReferenceCount: Int {
        referencePhotos.filter { $0.faceCount == 1 && $0.sharpness >= 0.4 && $0.contrast >= 0.25 }.count
    }
    private var styleReferenceTarget: Int { 10 }
    private var identityConfidenceLabel: String {
        if clearSoloReferenceCount >= 5 { return "Strong" }
        if clearSoloReferenceCount >= 3 { return "Good" }
        if clearSoloReferenceCount >= 1 { return "Warming up" }
        return "Low"
    }
    private var learningSignalSummary: LearningSignalSummary {
        let rated = feedbackHistory.filter { $0.preferenceSignal != 0 }
        let highRated = rated.filter(\.isPositiveSignal)
        let lowRated = rated.filter(\.isNegativeSignal)
        let recentCount = feedbackHistory.filter {
            Date().timeIntervalSince($0.createdAt) <= 30 * 86_400
        }.count

        guard rated.count >= 3 else {
            return LearningSignalSummary(
                icon: "sparkle.magnifyingglass",
                title: "Warming up",
                detail: "A few ratings are saved. Vesper is applying them gently until it has stronger signal.",
                tint: Color.vesperAccent,
                confidence: min(Double(rated.count) / 8.0, 0.35)
            )
        }

        guard !highRated.isEmpty, !lowRated.isEmpty else {
            return LearningSignalSummary(
                icon: "arrow.left.arrow.right",
                title: "Needs contrast",
                detail: "The model has mostly one-sided feedback, so it is learning slowly instead of overfitting.",
                tint: .orange,
                confidence: min(Double(rated.count) / 18.0, 0.48)
            )
        }

        func avg(_ items: [PhotoFeedback], _ keyPath: KeyPath<PhotoFeedback, Float>) -> Float {
            guard !items.isEmpty else { return 0.5 }
            return items.reduce(Float(0)) { $0 + $1[keyPath: keyPath] } / Float(items.count)
        }

        let separations = [
            abs(avg(highRated, \.photoQualityScore) - avg(lowRated, \.photoQualityScore)),
            abs(avg(highRated, \.photoExposureScore) - avg(lowRated, \.photoExposureScore)),
            abs(avg(highRated, \.photoCompositionScore) - avg(lowRated, \.photoCompositionScore)),
            abs(avg(highRated, \.photoGenuineSmileScore) - avg(lowRated, \.photoGenuineSmileScore)),
            abs(avg(highRated, \.photoEyeOpenConfidence) - avg(lowRated, \.photoEyeOpenConfidence)),
            abs(avg(highRated, \.photoColorHarmonyScore) - avg(lowRated, \.photoColorHarmonyScore))
        ]
        let separation = separations.reduce(0, +) / Float(separations.count)
        let evidence = min(Double(rated.count), 80)
        let evidenceConfidence = evidence / (evidence + 5)
        let clarity = min(max((Double(separation) - 0.04) / 0.18, 0.35), 1.0)
        let confidence = evidenceConfidence * clarity
        let recencyNote = recentCount > 0 ? " Recent ratings have the most influence." : " Newer ratings will outweigh stale taste data."

        if separation < 0.055 {
            return LearningSignalSummary(
                icon: "slider.horizontal.2.square",
                title: "Mixed signal",
                detail: "High- and low-rated photos look similar across the main scoring dimensions, so updates are dampened.\(recencyNote)",
                tint: .orange,
                confidence: confidence
            )
        }

        if confidence >= 0.72 {
            return LearningSignalSummary(
                icon: "checkmark.seal.fill",
                title: "Strong signal",
                detail: "Your feedback is producing a clear taste profile across quality, expression, composition, and color.\(recencyNote)",
                tint: .green,
                confidence: confidence
            )
        }

        return LearningSignalSummary(
            icon: "brain.head.profile",
            title: "Learning",
            detail: "Vesper has enough contrast to personalize rankings, while still keeping base photo quality in control.\(recencyNote)",
            tint: Color.vesperAccent,
            confidence: confidence
        )
    }
    private var learnedPreferenceInsights: [LearningInsight] {
        let rated = feedbackHistory.filter { $0.preferenceSignal != 0 }
        let highRated = rated.filter(\.isPositiveSignal)
        guard rated.count >= 2, !highRated.isEmpty else { return [] }

        func avg(_ values: [Float]) -> Float {
            guard !values.isEmpty else { return 0.5 }
            return values.reduce(0, +) / Float(values.count)
        }

        let quality = avg(highRated.map(\.photoQualityScore))
        let exposure = avg(highRated.map(\.photoExposureScore))
        let smile = avg(highRated.map(\.photoGenuineSmileScore))
        let color = avg(highRated.map(\.photoColorHarmonyScore))
        let reference = avg(highRated.map(\.photoReferenceScore))
        let eye = avg(highRated.map(\.photoEyeOpenConfidence))
        let closedEyeTolerance = BatchProcessor().learnedClosedEyeTolerance(from: Array(feedbackHistory))
        let selfFaces = highRated.filter(\.userFaceIdentified)
        let yaw = avg(selfFaces.map { abs($0.photoFaceYaw) })

        var insights: [LearningInsight] = []
        if quality >= 0.68 {
            insights.append(LearningInsight(icon: "scope", title: "Crisp shots", detail: "You tend to like sharper, cleaner photos.", tint: .cyan))
        } else if quality <= 0.45 {
            insights.append(LearningInsight(icon: "camera.filters", title: "Softer look", detail: "You seem open to less polished, more natural photos.", tint: .purple))
        }
        if exposure >= 0.72 {
            insights.append(LearningInsight(icon: "sun.max.fill", title: "Balanced light", detail: "Well-lit photos are scoring better with your feedback.", tint: .yellow))
        }
        if smile >= 0.62 {
            insights.append(LearningInsight(icon: "face.smiling.fill", title: "Warm expression", detail: "Smiles and approachable expressions are trending up.", tint: .green))
        }
        if color >= 0.66 {
            insights.append(LearningInsight(icon: "paintpalette.fill", title: "Color harmony", detail: "Cohesive palettes are becoming part of your taste profile.", tint: .orange))
        }
        if reference >= 0.62 {
            insights.append(LearningInsight(icon: "sparkles", title: "Reference style", detail: "Your highest-rated photos are aligning with your saved references.", tint: Color.vesperAccent))
        }
        if eye >= 0.78 {
            insights.append(LearningInsight(icon: "eye.fill", title: "Clear eyes", detail: "Open, visible eyes are a positive signal in your ratings.", tint: .blue))
        } else if closedEyeTolerance > 0.12 {
            insights.append(LearningInsight(icon: "eye.slash.fill", title: "Intentional closed eyes", detail: "Closed-eye shots can rank well when expression and framing work.", tint: .purple))
        }
        if selfFaces.count >= 5 {
            if yaw < 0.14 {
                insights.append(LearningInsight(icon: "person.crop.circle.fill", title: "Direct angle", detail: "You tend to prefer photos where your face is more front-facing.", tint: .indigo))
            } else if yaw > 0.24 {
                insights.append(LearningInsight(icon: "person.crop.square", title: "Candid angle", detail: "Slight off-camera angles appear to fit your taste.", tint: .mint))
            }
        }

        return Array(insights.prefix(5))
    }

    var body: some View {
        ZStack {
        ScrollView {
            VStack(spacing: 24) {

                // Reference Photos
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your Style")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            Text("Vesper learns your taste from these")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        PhotosPicker(selection: $referencePickerItems, maxSelectionCount: 20, matching: .images) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.caption.bold())
                                Text("Add")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(LinearGradient.vesperGold)
                            .clipShape(Capsule())
                        }
                        .onChange(of: referencePickerItems) { _, items in
                            Task { await addReferencePhotos(from: items) }
                        }
                    }

                    if referencePhotos.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.vesperAccent.opacity(0.5))
                            Text("No reference photos yet")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Add 5-10 favorite shots where you are clearly visible. Solo photos teach identity best; screenshots work when your face is easy to see.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                        .vesperCard(cornerRadius: 14)
                    } else {
                        referenceGuidanceCard

                        // Quality gate warning — low-quality references hurt taste profile accuracy
                        let lowQualityRefs = referencePhotos.filter { $0.sharpness < 0.4 || $0.contrast < 0.25 }
                        if !lowQualityRefs.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.subheadline)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(lowQualityRefs.count) reference photo\(lowQualityRefs.count == 1 ? "" : "s") may be low quality")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                    Text("Blurry or low-contrast references can reduce AI accuracy. Try replacing them with sharper shots.")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.6))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .background(.orange.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.25), lineWidth: 1))
                        }

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)
                        ], spacing: 6) {
                            ForEach(referencePhotos) { photo in
                                if let image = photo.thumbnail {
                                    let isLowQuality = photo.sharpness < 0.4 || photo.contrast < 0.25
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .aspectRatio(1, contentMode: .fill)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(isLowQuality ? .orange.opacity(0.7) : .clear, lineWidth: 2)
                                            )

                                        if isLowQuality {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .padding(3)
                                                .background(.black.opacity(0.6))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                                .offset(x: -22, y: -5)
                                        }

                                        Button {
                                            modelContext.delete(photo)
                                            do {
                                                try modelContext.save()
                                            } catch {
                                                modelContext.rollback()
                                                profileLogger.error("Reference photo delete failed: \(error.localizedDescription, privacy: .private)")
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.white)
                                                .background(Color.black.opacity(0.55))
                                                .clipShape(Circle())
                                        }
                                        .offset(x: 5, y: -5)
                                        .accessibilityLabel("Remove reference photo")
                                        .accessibilityHint("Deletes this style reference from Vesper")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .vesperCard(cornerRadius: 18)

                // Feedback & Learning
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What Vesper Has Learned")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Text("Use 1-5 star ratings in results to teach Vesper your taste")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    if feedbackHistory.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "brain")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.vesperAccent.opacity(0.5))
                            Text("No feedback yet")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Every rating helps Vesper adapt, with early feedback applied gently until it has more signal")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    } else {
                        HStack(spacing: 10) {
                            feedbackStat(icon: "star.fill", value: highRatedCount, label: "4-5 stars", color: .green)
                            feedbackStat(icon: "star.leadinghalf.filled", value: neutralCount, label: "3 stars", color: .orange)
                            feedbackStat(icon: "star.slash.fill", value: lowRatedCount, label: "1-2 stars", color: .red)
                        }

                        learningSignalCard

                        if !learnedPreferenceInsights.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Preference profile")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))

                                ForEach(learnedPreferenceInsights) { insight in
                                    HStack(spacing: 10) {
                                        Image(systemName: insight.icon)
                                            .font(.caption)
                                            .foregroundStyle(insight.tint.opacity(0.85))
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(insight.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.white.opacity(0.82))
                                            Text(insight.detail)
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.45))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(insight.tint.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(insight.tint.opacity(0.14), lineWidth: 1))
                                }
                            }
                            .padding(.top, 2)
                        }

                        let reasonedLowRatings = feedbackHistory.filter { $0.isNegativeSignal && !$0.reason.isEmpty }
                        if !reasonedLowRatings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recent feedback")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))

                                ForEach(reasonedLowRatings.prefix(5)) { fb in
                                    HStack(spacing: 10) {
                                        Image(systemName: "hand.thumbsdown.fill")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.7))
                                        Text(fb.reason)
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.7))
                                        Spacer()
                                        Text(fb.createdAt.formatted(.relative(presentation: .named)))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.top, 4)
                        }

                        Button {
                            showClearFeedbackConfirm = true
                        } label: {
                            Text("Clear all feedback")
                                .font(.subheadline)
                                .foregroundStyle(.red.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.red.opacity(0.15), lineWidth: 1))
                        }
                        .confirmationDialog("Clear all feedback? Vesper will start learning from scratch.", isPresented: $showClearFeedbackConfirm, titleVisibility: .visible) {
                            Button("Clear Feedback", role: .destructive) {
                                for fb in feedbackHistory { modelContext.delete(fb) }
                                do {
                                    try modelContext.save()
                                } catch {
                                    modelContext.rollback()
                                    profileLogger.error("Clear feedback failed: \(error.localizedDescription, privacy: .private)")
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                }
                .padding(20)
                .vesperCard(cornerRadius: 18)

                // Privacy note
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.vesperAccent.opacity(0.6))
                    Text("Photo scoring happens on your iPhone. Optional product feedback can include ratings, notes, prompts, scores, and low-resolution thumbnails.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(16)
                .vesperCard(cornerRadius: 12)

                // Privacy & Data — GDPR/CCPA controls + legal links
                privacySection
            }
            .padding(20)
            .padding(.bottom, 32)
        }
        .vesperBackground()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)

        // Learning overlay — shown while reference photos are being analyzed
        if isLearning {
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea()

                VStack(spacing: 28) {
                    ZStack {
                        Circle()
                            .fill(Color.vesperAccent.opacity(0.10))
                            .frame(width: 100, height: 100)
                            .blur(radius: 24)
                        Image(systemName: "brain.fill")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(Color.vesperAccent.opacity(0.9))
                    }

                    VStack(spacing: 8) {
                        Text("Vesper is learning your style")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text("Analyzing lighting, color, sharpness, pose, and composition.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        ProgressView(value: learningProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color.vesperAccent)
                            .frame(width: 220)

                        Text("\(Int(learningProgress * Double(learningTotal))) of \(learningTotal) photos analyzed")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .monospacedDigit()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.vesperAccent.opacity(0.5))
                        Text("All analysis happens on your device — nothing is uploaded")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .padding(32)
            }
            .transition(.opacity)
        }

        } // ZStack
    }

    private func feedbackStat(icon: String, value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text("\(value)")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .background(color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.15), lineWidth: 1))
        .frame(minHeight: 116)
        .frame(maxWidth: .infinity)
    }

    private var learningSignalCard: some View {
        let summary = learningSignalSummary

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: summary.icon)
                    .font(.subheadline)
                    .foregroundStyle(summary.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.50))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            ProgressView(value: summary.confidence, total: 1.0)
                .progressViewStyle(.linear)
                .tint(summary.tint)
                .accessibilityLabel("Learning confidence")
        }
        .padding(12)
        .background(summary.tint.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(summary.tint.opacity(0.16), lineWidth: 1))
    }

    private var referenceGuidanceCard: some View {
        let needsMore = referencePhotos.count < 5
        let hasManyGroupRefs = multiPersonReferenceCount >= max(2, referencePhotos.count / 2)
        let tint: Color = hasManyGroupRefs || clearSoloReferenceCount == 0 ? .orange : Color.vesperAccent

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: hasManyGroupRefs ? "person.2.badge.gearshape.fill" : "checkmark.seal.fill")
                    .foregroundStyle(tint)
                    .font(.subheadline)
                Text(needsMore ? "Reference profile is still warming up" : "Reference profile is ready")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
            }

            HStack(spacing: 10) {
                readinessPill(title: "Identity", value: identityConfidenceLabel, tint: tint)
                readinessPill(title: "Style", value: "\(min(referencePhotos.count, styleReferenceTarget))/\(styleReferenceTarget)", tint: Color.vesperAccent)
            }

            Text(referenceGuidanceText(needsMore: needsMore, hasManyGroupRefs: hasManyGroupRefs))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    private func readinessPill(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(tint.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func referenceGuidanceText(needsMore: Bool, hasManyGroupRefs: Bool) -> String {
        if hasManyGroupRefs {
            return "Several references include multiple people. Add a few clear solo photos so Vesper can identify you more reliably."
        }
        if needsMore {
            return "Add a few more clear favorites for stronger taste and face matching. Solo photos are the best anchors."
        }
        return "For best results, keep a mix of clear solo photos and shots that represent your actual style."
    }

    // MARK: - Privacy & Data section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Privacy & Data")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Your data stays on device. You can export or delete it at any time.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))

            VStack(spacing: 10) {
                // Export — writes a JSON file to tmp, shows a Share Sheet
                Button {
                    Task { await exportAllData() }
                } label: {
                    privacyRow(icon: "square.and.arrow.up", label: "Export my data", tint: .white)
                }

                // Delete all — double-confirm destructive action
                Button {
                    showDeleteAllConfirm = true
                } label: {
                    privacyRow(icon: "trash", label: "Delete all my data", tint: .red)
                }

                // Legal — required links for App Store review
                Link(destination: URL(string: "https://vesper.app/privacy")!) {
                    privacyRow(icon: "hand.raised.fill", label: "Privacy Policy", tint: .white.opacity(0.7))
                }
                Link(destination: URL(string: "https://vesper.app/terms")!) {
                    privacyRow(icon: "doc.text.fill", label: "Terms of Service", tint: .white.opacity(0.7))
                }
            }
        }
        .padding(20)
        .vesperCard(cornerRadius: 18)
        .confirmationDialog(
            "Delete all Vesper data?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all reference photos, feedback, batch history, prompts, and style-quiz results from this device. It cannot be undone. Your photos in the Photos app are not affected.")
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportFileURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Delete Failed", isPresented: $showDeleteAllError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Vesper could not delete all local data. Please try again.")
        }
    }

    private func privacyRow(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(tint)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Export / Delete actions

    private func exportAllData() async {
        let snapshot = VesperDataExport(
            exportedAt: Date(),
            referencePhotos: referencePhotos.map {
                VesperDataExport.ReferencePhotoExport(
                    createdAt: $0.createdAt,
                    brightness: $0.brightness,
                    saturation: $0.saturation,
                    warmth: $0.warmth,
                    contrast: $0.contrast,
                    sharpness: $0.sharpness,
                    avgFaceYaw: $0.avgFaceYaw,
                    faceCount: $0.faceCount
                )
            },
            feedback: feedbackHistory.map {
                VesperDataExport.FeedbackExport(
                    createdAt: $0.createdAt,
                    liked: $0.liked,
                    isNeutral: $0.isNeutral,
                    starRating: $0.effectiveStarRating,
                    reason: $0.reason,
                    purposeTag: $0.purposeTag
                )
            },
            batchHistory: batchHistory.map {
                VesperDataExport.BatchHistoryExport(
                    createdAt: $0.createdAt,
                    category: $0.category,
                    aesthetic: $0.aesthetic,
                    promptText: $0.promptText,
                    isPromptMode: $0.isPromptMode,
                    pickCount: $0.pickCount,
                    totalPhotos: $0.totalPhotos,
                    customName: $0.customName
                )
            }
        )
        guard let data = try? JSONEncoder.vesperPretty.encode(snapshot) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-export-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
            await MainActor.run {
                exportFileURL = url
                showExportShare = true
            }
        } catch {
            profileLogger.error("Export failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func deleteAllData() {
        // Remove all SwiftData records.
        for p in referencePhotos { modelContext.delete(p) }
        for f in feedbackHistory { modelContext.delete(f) }
        for b in batchHistory { modelContext.delete(b) }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            profileLogger.error("Delete-all save failed: \(error.localizedDescription, privacy: .private)")
            showDeleteAllError = true
            return
        }

        // Clear AppStorage flags so the user can re-onboard with a clean slate.
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasCompletedStyleQuiz")
        UserDefaults.standard.removeObject(forKey: "hasSeenResultsOnce")
        UserDefaults.standard.removeObject(forKey: "telemetryOptIn")
        UserDefaults.standard.removeObject(forKey: "hasAnsweredPhotoShare")
        UserDefaults.standard.removeObject(forKey: "photoShareOptIn")
        UserDefaults.standard.removeObject(forKey: "autoCreateRatingAlbums")
        UserDefaults.standard.removeObject(forKey: "completedBatchCount")
        UserDefaults.standard.removeObject(forKey: "lastPickCount")
        PromptHistory.clear()
    }

    private func addReferencePhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        learningTotal = items.count
        learningProgress = 0
        withAnimation(.easeInOut(duration: 0.25)) { isLearning = true }

        let service = ReferencePhotoService(context: modelContext)
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                learningProgress = Double(i + 1) / Double(items.count)
                continue
            }
            await service.add(image: image)
            learningProgress = Double(i + 1) / Double(items.count)
        }

        withAnimation(.easeInOut(duration: 0.3)) { isLearning = false }
        referencePickerItems = []
    }
}

#Preview {
    NavigationStack {
        ProfileView()
    }
}

// NOTE: ShareSheet lives in ResultsView.swift at module scope — we reuse it
// here rather than redeclare a duplicate UIViewControllerRepresentable.

// MARK: - Data Export payload (GDPR/CCPA)
//
// Exported JSON intentionally excludes thumbnail blobs and CLIP embeddings —
// both are derived data (thumbnails come from Photos, embeddings are a ML artifact)
// and including them would make the export unwieldy. Metadata and feedback are
// what matter for a data-portability request.

struct VesperDataExport: Codable {
    let exportedAt: Date
    let referencePhotos: [ReferencePhotoExport]
    let feedback: [FeedbackExport]
    let batchHistory: [BatchHistoryExport]

    struct ReferencePhotoExport: Codable {
        let createdAt: Date
        let brightness: Float
        let saturation: Float
        let warmth: Float
        let contrast: Float
        let sharpness: Float
        let avgFaceYaw: Float
        let faceCount: Int
    }
    struct FeedbackExport: Codable {
        let createdAt: Date
        let liked: Bool
        let isNeutral: Bool
        let starRating: Int
        let reason: String
        let purposeTag: String
    }
    struct BatchHistoryExport: Codable {
        let createdAt: Date
        let category: String
        let aesthetic: String
        let promptText: String
        let isPromptMode: Bool
        let pickCount: Int
        let totalPhotos: Int
        let customName: String
    }
}

private extension JSONEncoder {
    static var vesperPretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
