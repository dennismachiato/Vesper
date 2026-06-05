//
//  AIDiagnosticsView.swift
//  Vesper
//

import SwiftUI

enum AIDiagnosticPool: String, CaseIterable {
    case topPicks
    case runnerUps
    case deleteCandidates
    case similars

    var title: String {
        switch self {
        case .topPicks: return "Top"
        case .runnerUps: return "Review"
        case .deleteCandidates: return "Delete"
        case .similars: return "Similar"
        }
    }

    var icon: String {
        switch self {
        case .topPicks: return "trophy.fill"
        case .runnerUps: return "plus.circle.fill"
        case .deleteCandidates: return "trash.fill"
        case .similars: return "rectangle.stack.fill"
        }
    }

    var tint: Color {
        switch self {
        case .topPicks: return Color.vesperAccent
        case .runnerUps: return .cyan
        case .deleteCandidates: return .red
        case .similars: return .orange
        }
    }
}

struct AIDiagnosticPhoto: Identifiable {
    let result: PhotoResult
    let pool: AIDiagnosticPool
    let rating: Int?

    var id: UUID { result.id }
}

struct AIDiagnosticIssue: Identifiable, Equatable {
    enum Severity: String {
        case info = "Info"
        case warning = "Warning"
        case review = "Review"
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let count: Int
}

enum AIDiagnosticAnalyzer {
    static func allPhotos(
        topPicks: [PhotoResult],
        runnerUps: [PhotoResult],
        deleteCandidates: [PhotoResult],
        similars: [PhotoResult],
        ratings: [UUID: Int]
    ) -> [AIDiagnosticPhoto] {
        var seen = Set<UUID>()
        var photos: [AIDiagnosticPhoto] = []

        func append(_ results: [PhotoResult], pool: AIDiagnosticPool) {
            for result in results where !seen.contains(result.id) {
                seen.insert(result.id)
                photos.append(AIDiagnosticPhoto(result: result, pool: pool, rating: ratings[result.id]))
            }
        }

        append(topPicks, pool: .topPicks)
        append(runnerUps, pool: .runnerUps)
        append(deleteCandidates, pool: .deleteCandidates)
        append(similars, pool: .similars)
        return photos
    }

    static func issues(for photos: [AIDiagnosticPhoto]) -> [AIDiagnosticIssue] {
        let obscuredClosed = photos.filter {
            $0.result.eyeState == .closed && $0.result.eyeOcclusionScore > 0.55
        }
        let confidentClosedTopPicks = photos.filter {
            $0.pool == .topPicks && $0.result.eyeState == .closed && $0.result.eyeOpenConfidence < 0.30
        }
        let uncertainTopPicks = photos.filter {
            $0.pool == .topPicks && $0.result.eyeState == .unknown && $0.result.eyeOcclusionScore < 0.45
        }
        let unevenVisibleEyes = photos.filter {
            $0.result.hasFace && $0.result.eyeSymmetryScore < 0.55 && $0.result.eyeOcclusionScore < 0.45
        }
        let weakSimilarWinners = photos.filter {
            $0.pool == .topPicks && $0.result.batchRelativeScore < 0.45
        }
        let lowIdentityMatches = photos.filter {
            $0.result.faceCount > 1 && $0.result.userFaceIdentified && $0.result.userFaceMatchConfidence < 0.56
        }
        let noDeleteCandidates = photos.contains { $0.pool == .deleteCandidates } == false && photos.count >= 10

        var issues: [AIDiagnosticIssue] = []
        if !obscuredClosed.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "obscuredClosed",
                severity: .warning,
                title: "Obscured eyes labeled closed",
                detail: "Photos with high occlusion should usually be uncertain, not confident blinks.",
                count: obscuredClosed.count
            ))
        }
        if !confidentClosedTopPicks.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "closedTopPicks",
                severity: .review,
                title: "Closed-eye top picks",
                detail: "Review whether expression and angle justify these picks.",
                count: confidentClosedTopPicks.count
            ))
        }
        if !uncertainTopPicks.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "uncertainTopPicks",
                severity: .info,
                title: "Uncertain eye top picks",
                detail: "These may be fine, but are useful for checking sunglasses, shadows, and side angles.",
                count: uncertainTopPicks.count
            ))
        }
        if !unevenVisibleEyes.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "unevenEyes",
                severity: .review,
                title: "Visible eye asymmetry",
                detail: "Check if one eye reads smaller, mid-blink, or landmark detection is off.",
                count: unevenVisibleEyes.count
            ))
        }
        if !weakSimilarWinners.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "weakSimilarWinners",
                severity: .warning,
                title: "Weak similar-frame winners",
                detail: "A top pick lost the within-batch comparison; review the cluster.",
                count: weakSimilarWinners.count
            ))
        }
        if !lowIdentityMatches.isEmpty {
            issues.append(AIDiagnosticIssue(
                id: "lowIdentityMatches",
                severity: .review,
                title: "Low-confidence identity matches",
                detail: "Group-photo scoring may be anchored to the wrong face.",
                count: lowIdentityMatches.count
            ))
        }
        if noDeleteCandidates {
            issues.append(AIDiagnosticIssue(
                id: "noDeletes",
                severity: .info,
                title: "No deletion candidates",
                detail: "For large cleanup batches, confirm the fallback is surfacing weak review photos.",
                count: 0
            ))
        }
        return issues
    }
}

#if DEBUG
struct AIDiagnosticsView: View {
    let topPicks: [PhotoResult]
    let runnerUps: [PhotoResult]
    let deleteCandidates: [PhotoResult]
    let similars: [PhotoResult]
    let ratings: [UUID: Int]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPool: AIDiagnosticPool?

    private var photos: [AIDiagnosticPhoto] {
        AIDiagnosticAnalyzer.allPhotos(
            topPicks: topPicks,
            runnerUps: runnerUps,
            deleteCandidates: deleteCandidates,
            similars: similars,
            ratings: ratings
        )
    }

    private var filteredPhotos: [AIDiagnosticPhoto] {
        guard let selectedPool else { return photos }
        return photos.filter { $0.pool == selectedPool }
    }

    private var issues: [AIDiagnosticIssue] {
        AIDiagnosticAnalyzer.issues(for: photos)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    evaluationCoverageSection
                    issueSection
                    filterSection
                    photoSignalList
                }
                .padding(.vertical, 18)
            }
            .background(LinearGradient.vesperBg.ignoresSafeArea())
            .navigationTitle("AI Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.vesperAccent)
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Signals")
                .font(.headline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                diagnosticMetric("Photos", "\(photos.count)", "photo.stack", Color.vesperAccent)
                diagnosticMetric("Rated", "\(ratings.count)", "star.fill", .green)
                diagnosticMetric("Issues", "\(issues.count)", "exclamationmark.triangle.fill", issues.isEmpty ? .green : .orange)
                diagnosticMetric("Avg Score", averageCompositeLabel, "gauge.with.dots.needle.67percent", .cyan)
            }
            .padding(.horizontal)
        }
    }

    private var evaluationCoverageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evaluation Coverage")
                .font(.headline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            VStack(spacing: 8) {
                coverageRow(title: "Obscured eyes", detail: "Sunglasses, shadows, hair", count: count { $0.result.eyeOcclusionScore > 0.55 }, icon: "sunglasses.fill", tint: .teal)
                coverageRow(title: "Closed eyes", detail: "Confident blink/closed-eye frames", count: count { $0.result.eyeState == .closed }, icon: "eye.slash.fill", tint: .purple)
                coverageRow(title: "Uneven eyes", detail: "Visible eye asymmetry", count: count { $0.result.eyeSymmetryScore < 0.55 && $0.result.eyeOcclusionScore < 0.45 }, icon: "eye.trianglebadge.exclamationmark", tint: .orange)
                coverageRow(title: "Group identity", detail: "Multiple faces with face matching", count: count { $0.result.faceCount > 1 }, icon: "person.3.fill", tint: .cyan)
                coverageRow(title: "Similar frames", detail: "Burst or same-moment comparison", count: count { $0.pool == .similars || $0.result.batchRelativeScore != 0.5 }, icon: "rectangle.stack.fill", tint: .yellow)
            }
            .padding(.horizontal)
        }
    }

    private var issueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flags")
                .font(.headline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            if issues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("No diagnostic flags in this batch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
                .padding(14)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issueIcon(issue.severity))
                                .foregroundStyle(issueColor(issue.severity))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(issue.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    if issue.count > 0 {
                                        Text("\(issue.count)")
                                            .font(.caption.bold().monospacedDigit())
                                            .foregroundStyle(issueColor(issue.severity))
                                    }
                                }
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.48))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(issueColor(issue.severity).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(issueColor(issue.severity).opacity(0.16), lineWidth: 1))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(title: "All", icon: "square.grid.2x2.fill", tint: Color.vesperAccent, selected: selectedPool == nil) {
                    selectedPool = nil
                }
                ForEach(AIDiagnosticPool.allCases, id: \.self) { pool in
                    filterButton(title: pool.title, icon: pool.icon, tint: pool.tint, selected: selectedPool == pool) {
                        selectedPool = pool
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var photoSignalList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Raw Photo Signals")
                .font(.headline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            LazyVStack(spacing: 10) {
                ForEach(Array(filteredPhotos.enumerated()), id: \.element.id) { index, photo in
                    diagnosticPhotoRow(photo, rank: index + 1)
                }
            }
            .padding(.horizontal)
        }
    }

    private var averageCompositeLabel: String {
        guard !photos.isEmpty else { return "0.00" }
        let avg = photos.map(\.result.compositeScore).reduce(0, +) / Float(photos.count)
        return String(format: "%.2f", avg)
    }

    private func count(where predicate: (AIDiagnosticPhoto) -> Bool) -> Int {
        photos.filter(predicate).count
    }

    private func diagnosticMetric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.42))
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func coverageRow(title: String, detail: String, count: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Text("\(count)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(count > 0 ? tint : .white.opacity(0.28))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.10 : 0.04))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func filterButton(title: String, icon: String, tint: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundStyle(selected ? .black : tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(selected ? tint : tint.opacity(0.10))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(selected ? 0 : 0.18), lineWidth: 1))
        }
    }

    private func diagnosticPhotoRow(_ photo: AIDiagnosticPhoto, rank: Int) -> some View {
        let result = photo.result
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(uiImage: result.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .clipped()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("#\(rank)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white.opacity(0.52))
                        Label(photo.pool.title, systemImage: photo.pool.icon)
                            .font(.caption.bold())
                            .foregroundStyle(photo.pool.tint)
                        if let rating = photo.rating {
                            Label("\(rating)", systemImage: "star.fill")
                                .font(.caption.bold())
                                .foregroundStyle(ratingTint(rating))
                        }
                        Spacer()
                        Text(String(format: "%.2f", result.compositeScore))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(Color.vesperAccent)
                    }

                    Text(result.reasoning.isEmpty ? "No reasoning shown for this pool" : result.reasoning)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }

            VStack(spacing: 7) {
                signalBar("Quality", result.qualityScore, tint: .cyan)
                signalBar("Eyes", result.eyeOpenConfidence, detail: result.eyeState.rawValue, tint: result.eyeState == .closed ? .red : Color.vesperAccent)
                signalBar("Occlusion", result.eyeOcclusionScore, tint: .teal)
                signalBar("Symmetry", result.eyeSymmetryScore, tint: .orange)
                signalBar("Face match", result.userFaceMatchConfidence, detail: result.userFaceIdentified ? "identified" : "not matched", tint: .purple)
                signalBar("Reference", result.referenceScore ?? 0.5, detail: result.referenceScore == nil ? "none" : nil, tint: .green)
                signalBar("Feedback", result.feedbackScore ?? 0.5, detail: result.feedbackScore == nil ? "none" : nil, tint: .yellow)
                signalBar("Batch compare", result.batchRelativeScore, detail: result.batchComparisonNote.isEmpty ? nil : result.batchComparisonNote, tint: .pink)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func signalBar(_ title: String, _ value: Float, detail: String? = nil, tint: Color) -> some View {
        let clamped = min(max(value, 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.42))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer()
                Text(String(format: "%.2f", clamped))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.60))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(tint.opacity(0.75))
                        .frame(width: proxy.size.width * CGFloat(clamped))
                }
            }
            .frame(height: 5)
        }
    }

    private func issueIcon(_ severity: AIDiagnosticIssue.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .review: return "magnifyingglass.circle.fill"
        }
    }

    private func issueColor(_ severity: AIDiagnosticIssue.Severity) -> Color {
        switch severity {
        case .info: return .cyan
        case .warning: return .orange
        case .review: return Color.vesperAccent
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
}
#endif
