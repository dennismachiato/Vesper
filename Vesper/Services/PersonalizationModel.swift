//
//  PersonalizationModel.swift
//  Vesper
//

import Foundation

enum VesperModelMetadata {
    static let scoringVersion = "2.1"
    static let identityProvider = "face-crop-clip-v1"
    static let preferenceModel = "bayesian-pairwise-v2"
}

enum VesperPerformanceBudget {
    static let targetAnalysisSecondsPerPhoto = 2.5
}

protocol FaceIdentityEmbeddingProvider: Sendable {
    var identifier: String { get }
    func similarity(candidate: [Float], references: [[Float]]) -> Float?
}

struct CLIPFaceIdentityProvider: FaceIdentityEmbeddingProvider {
    let identifier = VesperModelMetadata.identityProvider

    func similarity(candidate: [Float], references: [[Float]]) -> Float? {
        guard !candidate.isEmpty, !references.isEmpty else { return nil }
        let similarities = references
            .filter { !$0.isEmpty }
            .map { CLIPEmbedder.cosineSimilarity(candidate, $0) }
        guard let maxSimilarity = similarities.max(), !similarities.isEmpty else { return nil }
        let averageSimilarity = similarities.reduce(0, +) / Float(similarities.count)
        return maxSimilarity * 0.65 + averageSimilarity * 0.35
    }
}

struct TasteControls: Codable, Equatable, Sendable {
    var technicalQuality: Float = 1.0
    var expression: Float = 1.0
    var composition: Float = 1.0
    var personalStyle: Float = 1.0

    static let `default` = TasteControls()

    static var current: TasteControls {
        let defaults = UserDefaults.standard
        return TasteControls(
            technicalQuality: defaults.floatValue(forKey: Keys.technicalQuality, fallback: 1),
            expression: defaults.floatValue(forKey: Keys.expression, fallback: 1),
            composition: defaults.floatValue(forKey: Keys.composition, fallback: 1),
            personalStyle: defaults.floatValue(forKey: Keys.personalStyle, fallback: 1)
        ).clamped()
    }

    var dimensionMultipliers: [String: Float] {
        [
            "qualityScore": technicalQuality,
            "exposureScore": 0.6 + technicalQuality * 0.4,
            "genuineSmileScore": expression,
            "eyeOpenConfidence": 0.65 + expression * 0.35,
            "compositionScore": composition,
            "colorHarmonyScore": personalStyle,
            "aestheticScore": personalStyle
        ]
    }

    func clamped() -> TasteControls {
        TasteControls(
            technicalQuality: min(max(technicalQuality, 0.75), 1.25),
            expression: min(max(expression, 0.75), 1.25),
            composition: min(max(composition, 0.75), 1.25),
            personalStyle: min(max(personalStyle, 0.75), 1.25)
        )
    }

    enum Keys {
        static let technicalQuality = "tasteControlTechnicalQuality"
        static let expression = "tasteControlExpression"
        static let composition = "tasteControlComposition"
        static let personalStyle = "tasteControlPersonalStyle"

        static let all = [technicalQuality, expression, composition, personalStyle]
    }
}

private extension UserDefaults {
    func floatValue(forKey key: String, fallback: Float) -> Float {
        object(forKey: key) == nil ? fallback : float(forKey: key)
    }
}

struct PersonalEvaluationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let modelVersion: String
    let purposeTag: String
    let predictedScore: Float
    let predictionConfidence: Float
    let predictedEyeState: String
    let eyeOpenConfidence: Float
    let eyeOcclusionScore: Float
    let identityConfidence: Float
    let userRating: Int
    let reason: String
}

struct PersonalEvaluationSummary: Equatable {
    let sampleCount: Int
    let meanAbsoluteError: Float
    let highConfidenceErrorRate: Float

    static let empty = PersonalEvaluationSummary(
        sampleCount: 0,
        meanAbsoluteError: 0,
        highConfidenceErrorRate: 0
    )
}

final class PersonalEvaluationStore: @unchecked Sendable {
    static let shared = PersonalEvaluationStore()

    private let lock = NSLock()
    private let maxRecords = 1_000
    private let fileURL: URL

    private init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("VesperModel", isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        fileURL = directory.appendingPathComponent("personal-evaluation.json")
    }

    func record(result: PhotoResult, rating: Int, reason: String, purposeTag: String) {
        let record = PersonalEvaluationRecord(
            id: UUID(),
            createdAt: Date(),
            modelVersion: result.modelVersion,
            purposeTag: purposeTag,
            predictedScore: result.compositeScore,
            predictionConfidence: result.modelConfidence,
            predictedEyeState: result.eyeState.rawValue,
            eyeOpenConfidence: result.eyeOpenConfidence,
            eyeOcclusionScore: result.eyeOcclusionScore,
            identityConfidence: result.userFaceMatchConfidence,
            userRating: min(max(rating, 1), 5),
            reason: reason
        )

        DispatchQueue.global(qos: .utility).async { [self] in
            append(record)
        }
    }

    private func append(_ record: PersonalEvaluationRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadUnlocked()
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        saveUnlocked(records)
    }

    func summary() -> PersonalEvaluationSummary {
        lock.lock()
        defer { lock.unlock() }
        let records = loadUnlocked()
        guard !records.isEmpty else { return .empty }

        let errors = records.map { record -> Float in
            let normalizedRating = Float(record.userRating - 1) / 4
            return abs(record.predictedScore - normalizedRating)
        }
        let meanError = errors.reduce(0, +) / Float(errors.count)

        let highConfidence = zip(records, errors).filter { $0.0.predictionConfidence >= 0.75 }
        let highConfidenceErrors = highConfidence.filter { $0.1 >= 0.35 }.count
        let errorRate = highConfidence.isEmpty
            ? 0
            : Float(highConfidenceErrors) / Float(highConfidence.count)

        return PersonalEvaluationSummary(
            sampleCount: records.count,
            meanAbsoluteError: meanError,
            highConfidenceErrorRate: errorRate
        )
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadUnlocked() -> [PersonalEvaluationRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([PersonalEvaluationRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func saveUnlocked(_ records: [PersonalEvaluationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

enum ModelConfidenceEstimator {
    static func confidence(
        quality: Float,
        exposure: Float,
        composition: Float,
        eyeState: EyeState,
        eyeOpenConfidence: Float,
        eyeOcclusion: Float,
        identityConfidence: Float,
        hasFace: Bool,
        hasReference: Bool,
        hasFeedback: Bool
    ) -> Float {
        let technicalAgreement = 1 - standardDeviation([quality, exposure, composition])
        let eyeReliability: Float
        if !hasFace {
            eyeReliability = 0.72
        } else if eyeState == .unknown {
            eyeReliability = max(0.28, 0.58 - eyeOcclusion * 0.22)
        } else {
            eyeReliability = 0.52 + abs(eyeOpenConfidence - 0.5) * 0.72
        }

        let identityReliability: Float
        if hasReference {
            identityReliability = identityConfidence > 0 ? identityConfidence : 0.42
        } else {
            identityReliability = 0.62
        }

        let personalizationReliability: Float = hasFeedback ? 0.78 : 0.58
        let raw = technicalAgreement * 0.34
            + eyeReliability * 0.25
            + identityReliability * 0.23
            + personalizationReliability * 0.18
        return min(max(raw, 0.2), 0.96)
    }

    static func identityConfidence(
        similarity: Float,
        margin: Float,
        referenceCount: Int
    ) -> Float {
        let similarityScore = min(max((similarity - 0.60) / 0.30, 0), 1)
        let marginScore = min(max(margin / 0.15, 0), 1)
        let evidenceScore = min(Float(referenceCount) / 5, 1)
        return min(max(
            similarityScore * 0.58 + marginScore * 0.27 + evidenceScore * 0.15,
            0
        ), 1)
    }

    private static func standardDeviation(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        return min(sqrt(variance), 1)
    }
}
