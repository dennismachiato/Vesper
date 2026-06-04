//
//  BatchProcessor.swift
//  Vesper
//
//  Created by Dennis Mach on 4/2/26.
//

import SwiftUI
import PhotosUI

struct PhotoResult: Identifiable {
    let id = UUID()
    let image: UIImage
    let reasoning: String
    var assetIdentifier: String = ""    // PHAsset localIdentifier — used for delete-from-library
    var qualityScore: Float = 0
    var exposureScore: Float = 0.5
    var compositionScore: Float = 0.5
    var genuineSmileScore: Float = 0.5
    var hasFace: Bool = false
    var eyeState: EyeState = .unknown
    var eyeOpenConfidence: Float = 0.5
    var faceYaw: Float = 0
    var colorHarmonyScore: Float = 0.5
    var userFaceIdentified: Bool = false
    var userFaceMatchConfidence: Float = 0
    var promptScore: Float? = nil
    var referenceScore: Float? = nil
    var feedbackScore: Float? = nil
    var category: String = ""
    var aesthetic: String = ""
    var promptText: String = ""
    var isPromptMode: Bool = false
    /// Rank-normalized composite score (0–1). Stretched across the batch so scores feel
    /// meaningfully spread — top photo ≈ 0.92, last photo ≈ 0.30 even when raw scores cluster.
    var compositeScore: Float = 0
}

/// Counting semaphore for Swift structured concurrency.
/// Limits how many analysis tasks run at the same time — without a cap, all N tasks
/// simultaneously block cooperative threads with Vision requests and compete for the
/// Neural Engine with CLIP inference, causing CoreML to hang and progress to freeze at 0%.
private actor AnalysisSemaphore {
    private var slots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { slots = n }
    func acquire() async {
        if slots > 0 { slots -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if let c = waiters.first { waiters.removeFirst(); c.resume() }
        else { slots += 1 }
    }
}

class BatchProcessor {
    private let analyzer = VisionAnalyzer()
    private let categoryScorer = CategoryScorer()
    private let aestheticScorer = AestheticScorer()
    private let referenceScorer = ReferenceScorer()

    /// Embeddings for "objectively bad photo" concepts — computed once per BatchProcessor instance.
    /// Negative CLIP signal: photos semantically similar to these get a quality penalty.
    private lazy var negativeEmbeddings: [[Float]] = {
        let descriptions = [
            "blurry out of focus photograph",
            "overexposed washed out image",
            "dark underexposed photo",
            "low quality grainy noisy photo",
            "poorly composed photo"
        ]
        return descriptions.compactMap { CLIPTextEmbedder.shared?.embed(prompt: $0) }
    }()

    /// Centroid CLIP embedding of the current-trend aesthetic vocabulary.
    /// Photos semantically close to these phrases get a small `trendScore` bump,
    /// which nudges modern-looking shots up when quality alone doesn't distinguish them.
    /// Lazy + cached: one model call per trend phrase per BatchProcessor instance.
    private lazy var trendEmbedding: [Float]? = {
        let trendPhrases = [
            "film grain aesthetic photo",
            "candid laughing moment",
            "y2k aesthetic selfie",
            "mirror selfie",
            "golden hour portrait",
            "dreamy soft focus photo",
            "vibey editorial photo",
            "retro analog film look",
            "soft focus bokeh background",
            "warm tones portrait",
            "minimalist clean composition",
            "candid unposed moment",
            "aesthetic lifestyle photo",
            "natural light portrait",
            "storybook photo warm"
        ]
        let embeddings = trendPhrases.compactMap { CLIPTextEmbedder.shared?.embed(prompt: $0) }
        guard !embeddings.isEmpty else { return nil }
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings { for i in 0..<dim { avg[i] += emb[i] } }
        let n = Float(embeddings.count)
        avg = avg.map { $0 / n }
        let mag = sqrt(avg.map { $0 * $0 }.reduce(0, +))
        guard mag > 0 else { return avg }
        return avg.map { $0 / mag }   // unit vector — ready for cosine similarity
    }()

    // MARK: - Entry point (images already loaded by ProcessingView)

    // All prompt-derived intent flags, computed once and reused throughout the pipeline.
    // Each flag suppresses (or flips) a penalty that would otherwise hurt photos matching
    // what the user actually asked for.
    struct PromptIntent {
        // ── Gaze / eyes ─────────────────────────────────────────
        let wantsLookingAway: Bool      // "looking away", "averted gaze"
        let wantsLookingAtCamera: Bool  // "eye contact", "facing camera"
        let wantsEyesClosed: Bool       // "eyes closed", "dreamy"
        // ── Motion / focus ──────────────────────────────────────
        let wantsBlurry: Bool           // "soft focus", "bokeh", "dreamy"
        let wantsMotion: Bool           // "motion blur", "action", "sports"
        // ── Exposure ────────────────────────────────────────────
        let wantsDark: Bool             // "dark", "moody", "night", "silhouette"
        let wantsHighKey: Bool          // "overexposed", "washed out", "bright white", "high key"
        // ── Pose / expression ───────────────────────────────────
        let wantsAwkward: Bool          // "awkward", "funny", "goofy", "candid", "silly"
        let wantsSerious: Bool          // "serious", "stoic", "no smile", "stern"
        // ── Aesthetic imperfection ──────────────────────────────
        let wantsImperfect: Bool        // "grainy", "vintage", "film", "retro", "lo-fi"
        // ── Subject type ────────────────────────────────────────
        /// True when the prompt explicitly involves people / faces / portraits.
        /// When false in prompt mode, eye/gaze/pose penalties are suppressed.
        let hasFaceContent: Bool
        /// True when the prompt asks for a tall / full-body composition
        /// ("tall", "full body", "statuesque", "makes me look tall").
        /// Gates whether `subjectHeight` is allowed to influence scoring —
        /// otherwise we don't want to penalise great headshots for being headshots.
        var wantsTallSubject: Bool = false
    }

    // MARK: - Low-rating reason -> dimension weight boost (Feature 5)

    /// Maps free-text low-rating reasons to dimension names that should receive a scoring boost.
    /// Returns a dict of dimension → multiplier (e.g. ["qualityScore": 1.25]).
    func dimensionHintsFromReasons(_ reasons: [String]) -> [String: Float] {
        var hints: [String: Float] = [:]
        let combined = reasons.joined(separator: " ").lowercased()

        let mappings: [(keywords: [String], dimension: String, boost: Float)] = [
            // Sharpness / focus
            (["blurry", "blur", "out of focus", "soft", "not sharp", "fuzzy", "unclear"], "qualityScore", 1.25),
            // Exposure
            (["dark", "too dark", "underexposed", "cant see", "too dim", "night", "shadowy"], "exposureScore", 1.20),
            (["bright", "overexposed", "washed out", "too bright", "blown", "glare"], "exposureScore", 1.15),
            // Background
            (["background", "busy background", "distracting", "cluttered", "messy", "noisy background"], "backgroundSharpness", 1.20),
            // Too many people / crowd — these hurt composition AND background cleanliness.
            // Applied to both dimensions so the signal is meaningful even when only one fires.
            (["too many people", "crowd", "crowded", "lots of people", "people in background",
              "people behind", "full of people", "group", "strangers"], "compositionScore", 1.30),
            (["too many people", "crowd", "crowded", "lots of people", "people in background",
              "people behind", "full of people", "strangers"], "backgroundSharpness", 1.25),
            // Composition / framing
            (["composition", "cropped", "cut off", "badly framed", "off center", "tilted",
              "horizon", "not centered"], "compositionScore", 1.25),
            // Eyes — explicitly distinguish "closed" vs generic "eyes" for stronger signal.
            // Includes natural-language orderings ("eyes are closed", "eyes were shut") so
            // typed reasons read casually still route to the stronger boost.
            (["closed eyes", "eyes closed", "eyes are closed", "eyes were closed",
              "eyes shut", "eyes are shut", "blink", "blinking", "half closed",
              "squinting", "looks tired", "tired eyes", "sleepy"], "eyeOpenConfidence", 1.40),
            (["eyes", "eye"], "eyeOpenConfidence", 1.25),
            // Smile / expression
            (["smile", "expression", "weird face", "bad expression", "not smiling",
              "forced smile", "unnatural", "awkward expression", "dead eyes"], "genuineSmileScore", 1.20),
            // Pose
            (["pose", "awkward", "bad pose", "standing weird", "posture", "slouching",
              "weird angle", "unflattering"], "poseScore", 1.20),
            // Color
            (["color", "colours", "colors", "bad color", "oversaturated", "washed",
              "dull colors", "too yellow", "too orange", "too blue", "color grading"], "colorHarmonyScore", 1.15),
        ]

        for mapping in mappings {
            if mapping.keywords.contains(where: { combined.contains($0) }) {
                hints[mapping.dimension] = max(hints[mapping.dimension] ?? 1.0, mapping.boost)
            }
        }
        return hints
    }

    // MARK: - Per-user weight learning (Feature 6)

    /// Computes per-dimension weight multipliers from any amount of feedback — fires from event #1.
    ///
    /// Uses Bayesian shrinkage so early feedback still moves the needle immediately but doesn't
    /// wildly overfit on 1–2 data points, and naturally smooths out as more events accumulate:
    ///
    ///   shrinkage = n / (n + k)   where k = 5 (equivalent to 5 "prior" neutral observations)
    ///   n=1  → 17% strength  (strongly biased toward no-change until more data arrives)
    ///   n=5  → 50% strength
    ///   n=10 → 67% strength
    ///   n=30 → 86% strength  (close to the old formula's effective strength at 30 events)
    ///   n=100 → 95% strength (converging — essentially fully trusted)
    ///
    /// The actual per-dimension delta (highRated_avg − low-rated_avg) is then scaled by shrinkage,
    /// so a single "eyes closed" low rating with qualityScore 0.3 vs. baseline 0.5 → delta −0.2
    /// → raw multiplier 0.70 → shrunk to 0.94 at n=1. Tangible but not overwhelming.
    private func preferenceEvidenceWeight(for feedback: PhotoFeedback, now: Date = Date()) -> Float {
        let days = Float(now.timeIntervalSince(feedback.createdAt) / 86_400)
        return exp(-0.003 * max(days, 0))
    }

    private func effectiveEvidenceCount(_ rawWeight: Float, cap: Float = 80) -> Float {
        min(max(rawWeight, 0), cap)
    }

    func learnedWeightMultipliers(from feedbackHistory: [PhotoFeedback]) -> [String: Float] {
        let now = Date()
        let weightedFeedback = feedbackHistory.map { feedback in
            (
                feedback: feedback,
                signal: feedback.preferenceSignal,
                evidenceWeight: preferenceEvidenceWeight(for: feedback, now: now)
            )
        }
        let highRatedWeighted = weightedFeedback
            .filter { $0.signal > 0 }
            .map { (feedback: $0.feedback, weight: $0.evidenceWeight * $0.signal) }
        let lowRatedWeighted = weightedFeedback
            .filter { $0.signal < 0 }
            .map { (feedback: $0.feedback, weight: $0.evidenceWeight * abs($0.signal)) }
        let rawEvidence = highRatedWeighted.map(\.weight).reduce(0, +) + lowRatedWeighted.map(\.weight).reduce(0, +)
        guard rawEvidence >= 0.25 else { return [:] }   // need at least one meaningful recent-ish event
        guard !highRatedWeighted.isEmpty, !lowRatedWeighted.isEmpty else { return [:] }

        // Bayesian shrinkage: with few events, pull the multiplier toward 1.0 (no change).
        // k=5 means 5 "pseudo-counts" worth of evidence are pre-loaded as a neutral prior.
        // Evidence is recency-weighted and capped so very old or very large histories cannot
        // drown out a newer preference shift.
        let n = effectiveEvidenceCount(rawEvidence)
        let shrinkage = n / (n + 5.0)

        func avg(_ values: [(feedback: PhotoFeedback, weight: Float)], _ keyPath: KeyPath<PhotoFeedback, Float>) -> Float {
            let totalWeight = values.map(\.weight).reduce(0, +)
            guard totalWeight > 0 else { return 0.5 }
            return values.reduce(Float(0)) { partial, item in
                partial + item.feedback[keyPath: keyPath] * item.weight
            } / totalWeight
        }

        let highRatedQuality     = avg(highRatedWeighted, \.photoQualityScore)
        let lowRatedQuality  = avg(lowRatedWeighted, \.photoQualityScore)
        let highRatedExposure    = avg(highRatedWeighted, \.photoExposureScore)
        let lowRatedExposure = avg(lowRatedWeighted, \.photoExposureScore)
        let highRatedComp        = avg(highRatedWeighted, \.photoCompositionScore)
        let lowRatedComp     = avg(lowRatedWeighted, \.photoCompositionScore)
        let highRatedSmile       = avg(highRatedWeighted, \.photoGenuineSmileScore)
        let lowRatedSmile    = avg(lowRatedWeighted, \.photoGenuineSmileScore)
        let highRatedEyes        = avg(highRatedWeighted, \.photoEyeOpenConfidence)
        let lowRatedEyes     = avg(lowRatedWeighted, \.photoEyeOpenConfidence)
        let highRatedHarmony     = avg(highRatedWeighted, \.photoColorHarmonyScore)
        let lowRatedHarmony  = avg(lowRatedWeighted, \.photoColorHarmonyScore)

        let dimensionDeltas = [
            abs(highRatedQuality - lowRatedQuality),
            abs(highRatedExposure - lowRatedExposure),
            abs(highRatedComp - lowRatedComp),
            abs(highRatedSmile - lowRatedSmile),
            abs(highRatedEyes - lowRatedEyes),
            abs(highRatedHarmony - lowRatedHarmony)
        ]
        let averageSeparation = dimensionDeltas.reduce(0, +) / Float(dimensionDeltas.count)
        let signalClarity = min(max((averageSeparation - 0.04) / 0.18, 0.65), 1.0)

        // Shrink delta toward 0 by data confidence and signal clarity, then scale.
        // Clamped to [0.75, 1.40] so learning never fully overrides the base formula.
        // When likes/low ratings look very similar, clarity dampens the update instead of
        // letting contradictory feedback cloud the model.
        func multiplier(highRatedAvg: Float, lowRatedAvg: Float) -> Float {
            let delta = (highRatedAvg - lowRatedAvg) * shrinkage * signalClarity
            return min(max(1.0 + delta * 1.5, 0.75), 1.40)
        }

        var weights: [String: Float] = [:]
        let qualMult    = multiplier(highRatedAvg: highRatedQuality,  lowRatedAvg: lowRatedQuality)
        let expMult     = multiplier(highRatedAvg: highRatedExposure, lowRatedAvg: lowRatedExposure)
        let compMult    = multiplier(highRatedAvg: highRatedComp,     lowRatedAvg: lowRatedComp)
        let smileMult   = multiplier(highRatedAvg: highRatedSmile,    lowRatedAvg: lowRatedSmile)
        let eyesMult    = multiplier(highRatedAvg: highRatedEyes,     lowRatedAvg: lowRatedEyes)
        let harmonyMult = multiplier(highRatedAvg: highRatedHarmony,  lowRatedAvg: lowRatedHarmony)

        // Only store if there's a real signal — avoids noise from near-identical scores
        if abs(qualMult    - 1.0) > 0.03 { weights["qualityScore"]       = qualMult    }
        if abs(expMult     - 1.0) > 0.03 { weights["exposureScore"]      = expMult     }
        if abs(compMult    - 1.0) > 0.03 { weights["compositionScore"]   = compMult    }
        if abs(smileMult   - 1.0) > 0.03 { weights["genuineSmileScore"]  = smileMult   }
        if abs(eyesMult    - 1.0) > 0.03 { weights["eyeOpenConfidence"]  = eyesMult    }
        if abs(harmonyMult - 1.0) > 0.03 { weights["colorHarmonyScore"]  = harmonyMult }
        return weights
    }

    /// Learns the user's preferred head angle (yaw) from high-rated photos where their OWN face was
    /// identified. Returns nil until there are ≥5 such samples — angle is personal and noisy, so
    /// it needs more evidence than the dimension weights before it influences ranking. The value is
    /// the mean absolute yaw (radians) of liked, identified self-photos; weightedScore then applies
    /// a small bonus to new photos whose user-face yaw sits close to it.
    func learnedPreferredYaw(from feedbackHistory: [PhotoFeedback]) -> Float? {
        let now = Date()
        let weighted = feedbackHistory
            .filter { $0.preferenceSignal > 0 && $0.userFaceIdentified }
            .map { (yaw: abs($0.photoFaceYaw), weight: preferenceEvidenceWeight(for: $0, now: now) * $0.preferenceSignal) }
        let totalWeight = weighted.map(\.weight).reduce(0, +)
        guard totalWeight >= 5 else { return nil }
        return weighted.reduce(Float(0)) { $0 + $1.yaw * $1.weight } / totalWeight
    }

    /// Learns whether closed-eye photos can be part of this user's taste.
    /// Returns 0...1 where 0 means use the default closed-eye penalty and 1 means a strong
    /// closed-eye portrait can be treated as intentional when expression/angle/style also work.
    func learnedClosedEyeTolerance(from feedbackHistory: [PhotoFeedback]) -> Float {
        let rated = feedbackHistory.filter { $0.preferenceSignal != 0 }
        let closedAll = rated.filter { $0.photoEyeOpenConfidence < 0.35 }
        let closedSelf = closedAll.filter(\.userFaceIdentified)
        let closed = closedSelf.isEmpty ? closedAll : closedSelf
        guard !closed.isEmpty else { return 0 }

        let highRatedClosed = closed.filter { $0.preferenceSignal > 0 }
        let lowRatedClosed = closed.filter { $0.preferenceSignal < 0 }
        let now = Date()
        let highRatedWeight = highRatedClosed.map { preferenceEvidenceWeight(for: $0, now: now) * $0.preferenceSignal }.reduce(0, +)
        let lowRatedWeight = lowRatedClosed.map { preferenceEvidenceWeight(for: $0, now: now) * abs($0.preferenceSignal) }.reduce(0, +)
        let rawEvidence = highRatedWeight + lowRatedWeight
        let n = effectiveEvidenceCount(rawEvidence)
        guard n > 0 else { return 0 }

        let likeRatio = highRatedWeight / rawEvidence
        let preference = max((likeRatio - 0.5) * 2.0, 0.0)
        guard preference > 0 else { return 0 }

        let shrinkage = n / (n + 5.0)
        let avgContext: Float
        if highRatedClosed.isEmpty || highRatedWeight <= 0 {
            avgContext = 0.5
        } else {
            avgContext = highRatedClosed.reduce(Float(0)) { partial, feedback in
                let weight = preferenceEvidenceWeight(for: feedback, now: now) * feedback.preferenceSignal
                return partial + closedEyeContextScore(
                    quality: feedback.photoQualityScore,
                    expression: feedback.photoGenuineSmileScore,
                    pose: 0.5,
                    composition: feedback.photoCompositionScore,
                    colorHarmony: feedback.photoColorHarmonyScore,
                    reference: feedback.photoReferenceScore,
                    yaw: feedback.photoFaceYaw
                ) * weight
            } / highRatedWeight
        }
        let contextConfidence = min(max((avgContext - 0.45) / 0.35, 0), 1)

        return min(preference * shrinkage * (0.65 + contextConfidence * 0.35), 1.0)
    }

    private func flatteringAngleScore(_ yaw: Float) -> Float {
        let absYaw = abs(yaw)
        switch absYaw {
        case ..<0.12:      return 0.78
        case 0.12..<0.45:  return 1.0
        case 0.45..<0.70:  return 0.74
        default:           return 0.35
        }
    }

    private func closedEyeContextScore(
        quality: Float,
        expression: Float,
        pose: Float,
        composition: Float,
        colorHarmony: Float,
        reference: Float,
        yaw: Float
    ) -> Float {
        let angle = flatteringAngleScore(yaw)
        let raw = (quality * 0.18)
                + (expression * 0.26)
                + (pose * 0.14)
                + (composition * 0.16)
                + (colorHarmony * 0.10)
                + (reference * 0.10)
                + (angle * 0.06)
        return min(max(raw, 0), 1)
    }

    func closedEyeContextScore(_ score: PhotoScore) -> Float {
        closedEyeContextScore(
            quality: score.qualityScore,
            expression: score.genuineSmileScore,
            pose: score.poseScore,
            composition: score.compositionScore,
            colorHarmony: score.colorHarmonyScore,
            reference: score.referenceScore ?? 0.5,
            yaw: score.faceYaw
        )
    }

    func closedEyePenaltyRelief(for score: PhotoScore, tolerance: Float) -> Float {
        guard score.hasFace, score.eyeState == .closed, tolerance > 0 else { return 0 }
        let contextGate = min(max((closedEyeContextScore(score) - 0.55) / 0.30, 0), 1)
        return min(max(tolerance, 0), 1) * contextGate
    }

    func processImages(
        images: [UIImage],
        assetIdentifiers: [String] = [],   // parallel array — empty string if unknown
        pickCount: Int,
        category: PhotoCategory,
        aesthetics: [AestheticStyle],
        tasteProfile: (brightness: Float, saturation: Float, warmth: Float, avgFaceCount: Float,
                       avgSharpness: Float, avgContrast: Float, avgFaceYaw: Float)? = nil,
        referenceEmbeddings: [[Float]] = [],   // individual per-reference CLIP embeddings
        avgEmbedding: [Float]? = nil,          // centroid fallback
        promptEmbedding: [Float]? = nil,
        promptText: String = "",
        isPromptMode: Bool = false,
        isDatingMode: Bool = false,
        isReferenceDriven: Bool = false,   // user opted to skip prompt/category and use refs as primary signal
        purposeTag: String = "",           // "social", "dating", "professional", "outfit", "cleanup", "general"
        datingVibe: String = "",
        datingAudience: String = "",
        likedEmbeddings: [WeightedEmbedding] = [],
        neutralEmbeddings: [WeightedEmbedding] = [],
        lowRatedEmbeddings: [WeightedEmbedding] = [],
        likedReasonEmbeddings: [WeightedEmbedding] = [],
        lowRatingReasonEmbeddings: [WeightedEmbedding] = [],
        contrastEmbeddings: [WeightedEmbedding] = [],   // "runner-up" embeddings — photos seen just before a high-rated photo
        feedbackHistory: [PhotoFeedback] = [],   // full history — used for weight learning
        lowRatingReasons: [String] = [],           // raw low-rating reason strings — used for dimension hints
        userFaceEmbeddings: [[Float]] = [],      // CLIP embeddings of face crops from reference photos — used to identify the user
        requireUniquePicks: Bool = true,         // when false, skip scene-diversity dedup
        onProgress: ((Int, Int) -> Void)? = nil   // (completed, total) — called on main actor
    ) async -> (topPicks: [PhotoResult], runnerUps: [PhotoResult], deleteCandidates: [PhotoResult], similars: [PhotoResult]) {
        guard !images.isEmpty else { return ([], [], [], []) }

        // 1. Detect all prompt intents at once
        var intent = PromptIntent(
            wantsLookingAway:     promptWantsLookingAway(promptText),
            wantsLookingAtCamera: promptWantsLookingAtCamera(promptText),
            wantsEyesClosed:      promptWantsEyesClosed(promptText),
            wantsBlurry:          promptWantsBlurry(promptText),
            wantsMotion:          promptWantsMotion(promptText),
            wantsDark:            promptWantsDark(promptText),
            wantsHighKey:         promptWantsHighKey(promptText),
            wantsAwkward:         promptWantsAwkward(promptText),
            wantsSerious:         promptWantsSerious(promptText),
            wantsImperfect:       promptWantsImperfect(promptText),
            hasFaceContent:       isPromptMode ? promptHasFaceContent(promptText) : true
        )
        intent.wantsTallSubject = isPromptMode && promptWantsTallSubject(promptText)
        let wantsLookingAway     = intent.wantsLookingAway
        let wantsLookingAtCamera = intent.wantsLookingAtCamera
        let hasFaceContent       = intent.hasFaceContent

        // 3. Whether reference / prompt / feedback paths are active
        let hasReference = !referenceEmbeddings.isEmpty || avgEmbedding != nil
        let needsCLIP    = promptEmbedding != nil || !likedEmbeddings.isEmpty
                           || !lowRatedEmbeddings.isEmpty || !lowRatingReasonEmbeddings.isEmpty
                           || !likedReasonEmbeddings.isEmpty || !contrastEmbeddings.isEmpty || hasReference
        let hasFeedback  = !likedEmbeddings.isEmpty || !neutralEmbeddings.isEmpty
                           || !lowRatedEmbeddings.isEmpty || !lowRatingReasonEmbeddings.isEmpty
                           || !likedReasonEmbeddings.isEmpty || !contrastEmbeddings.isEmpty

        // Recency decay constant: weight = exp(-k * days). k=0.003 → ~half weight at ~231 days.
        // Style preferences change slowly — keeping older feedback relevant longer improves consistency.
        let now = Date()
        let recencyWeight: @Sendable (Date) -> Float = { date in
            let days = Float(now.timeIntervalSince(date) / 86400)
            return exp(-0.003 * max(days, 0))
        }

        // 4. Dynamic reference weight: more references → more confident → higher weight
        //    Standard mode ramps from 0.25 (1 reference) to the Remote Config cap (default 0.40)
        //    at 8+ references. Reference-driven mode lifts the ceiling to 0.60 since the user
        //    explicitly chose "let my references decide" — references should dominate the score.
        let rcRefWeight     = RemoteConfigService.shared.referenceWeight   // default 0.40
        let dynamicRefWeight: Float = hasReference ? {
            let n = Float(max(referenceEmbeddings.count, avgEmbedding != nil ? 1 : 0))
            let ramp = min(n / 8.0, 1.0)
            if isReferenceDriven {
                // Reference-driven mode: 1 ref → 0.40, 4 refs → 0.50, 8+ refs → 0.60
                let cap: Float = max(rcRefWeight, 0.60)
                return 0.40 + ramp * (cap - 0.40)
            }
            // Standard mode: 1 ref → 0.25, 4 refs → 0.35, 8+ refs → full rcRefWeight
            return 0.25 + ramp * (rcRefWeight - 0.25)
        }() : 0.0

        // Feature 5: dimension hints from low-rating reasons (e.g. "blurry" → boost qualityScore weight)
        let dimHints = dimensionHintsFromReasons(lowRatingReasons)

        // Feature 6: per-user weight learning from historical feedback.
        // Starts from the first event, then uses shrinkage so early feedback is gentle.
        let learnedWeights = learnedWeightMultipliers(from: feedbackHistory)

        // Learned preferred head angle from liked, identified self-photos (nil until ≥5 samples)
        let preferredYaw = learnedPreferredYaw(from: feedbackHistory)
        let closedEyeTolerance = learnedClosedEyeTolerance(from: feedbackHistory)

        // Pre-compute lazy vars on the calling thread BEFORE spawning the task group.
        // Swift lazy stored properties are not thread-safe for concurrent first access —
        // 265 tasks simultaneously hitting an uninitialized lazy var causes a data race.
        // Capturing them here as local constants makes them safe value-type copies for tasks.
        let precomputedNegativeEmbs = negativeEmbeddings
        let precomputedTrendEmb = trendEmbedding

        // 2. Single-pass: Vision analysis + CLIP + category/aesthetic/reference scoring.
        // Bounded concurrency: at most 4 tasks run simultaneously. Without this cap all N tasks
        // compete for the Neural Engine at once (Vision × CLIP × N), exhausting cooperative
        // threads and causing CoreML to hang — which locks progress at 0%.
        let semaphore = AnalysisSemaphore(4)

        var scores: [PhotoScore] = await withTaskGroup(of: (Int, PhotoScore).self) { group in
            for i in images.indices {
                let img = images[i]
                group.addTask {
                    await semaphore.acquire()

                    guard !Task.isCancelled else {
                        await semaphore.release()
                        return (i, PhotoScore(image: img, qualityScore: 0.3))
                    }

                    // Vision analysis (face, pose, sharpness, exposure, color harmony, vibe)
                    var s = await self.analyzer.analyzePhoto(img)
                    s.originalIndex = i
                    guard !Task.isCancelled else {
                        await semaphore.release()
                        return (i, PhotoScore(image: img, qualityScore: 0.3))
                    }

                    if !isPromptMode {
                        let catScore = await self.categoryScorer.score(image: s.image, category: category)
                        // Take the max across all selected aesthetics — photo wins if it fits any of them
                        let aesScore = aesthetics.isEmpty ? 0.5
                            : aesthetics.map { self.aestheticScorer.score(image: s.image, aesthetic: $0) }.max() ?? 0.5
                        s.categoryScore = catScore
                        s.aestheticScore = aesScore
                    }

                    // Compute CLIP embedding first so reference scoring can reuse it.
                    // embedAsync suspends the task (not the thread) while the serial CLIP
                    // queue processes this image — allows the other 3 active tasks to run.
                    var imageEmb: [Float]? = nil
                    if let clipEmbedder = CLIPEmbedder.shared {
                        imageEmb = await clipEmbedder.embedAsync(image: s.image)
                    }
                    s.clipEmbedding = imageEmb
                    guard !Task.isCancelled else {
                        await semaphore.release()
                        return (i, PhotoScore(image: img, qualityScore: 0.3))
                    }

                    // User face identification — only runs when the user has reference face
                    // embeddings AND the photo has multiple significant faces to choose between.
                    // When a match is found, quality signals (eyes, smile, pose) are overridden
                    // with the identified face's data so scoring reflects HOW THE USER looks,
                    // not whoever happens to be the largest or most prominent face.
                    if !userFaceEmbeddings.isEmpty, s.candidateFaces.count > 1 {
                        if let match = await self.identifyUserFace(
                            in: s.image,
                            candidates: s.candidateFaces,
                            userFaceEmbeddings: userFaceEmbeddings
                        ) {
                            let userFace = s.candidateFaces[match.index]
                            s.eyeState          = userFace.eyeState
                            s.eyeOpenConfidence = userFace.eyeOpenConfidence
                            s.genuineSmileScore = userFace.genuineSmileScore
                            s.eyesOpen          = userFace.eyeState == .open
                            s.faceYaw           = userFace.faceYaw
                            s.faceBoundingBox   = userFace.boundingBox
                            s.userFaceIdentified = true
                            s.userFaceMatchConfidence = match.confidence

                            // Re-anchor sharpness, composition, and bokeh on the USER's face.
                            // analyzePhoto computed these against the dominant (largest) face — a
                            // stranger here — so without this we'd reward how sharp/well-composed the
                            // stranger is, not the user. Quality is re-blended using the user face's
                            // own detection confidence (same 0.65/0.35 split as analyzePhoto).
                            if let m = self.analyzer.userFaceMetrics(image: s.image, normalizedFaceBox: userFace.boundingBox) {
                                let qualityBase = 0.5 + userFace.detectionConfidence * 0.5
                                s.qualityScore        = (qualityBase * 0.65) + (m.subjectSharpness * 0.35)
                                s.compositionScore    = m.composition
                                s.backgroundSharpness = m.backgroundSharpness
                            }
                        }
                    } else if !userFaceEmbeddings.isEmpty, let solo = s.candidateFaces.first,
                              s.candidateFaces.count == 1 {
                        // Solo photo: the single (dominant) face's eyes/smile/yaw are already in `s`.
                        // We only need to confirm the face is the user so angle/expression learning
                        // applies to selfies — the most common "how do I look" shot.
                        if let confidence = await self.soloFaceMatchConfidence(solo, in: s.image, userFaceEmbeddings: userFaceEmbeddings) {
                            s.userFaceIdentified = true
                            s.userFaceMatchConfidence = confidence
                        }
                    }

                    // Reference scoring — reuses the embedding just computed above.
                    // Previously called embed(image:) (sync) which doubled CLIP queue traffic.
                    if let profile = tasteProfile, hasReference {
                        let avg = avgEmbedding ?? []
                        s.referenceScore = self.referenceScorer.score(
                            imageEmbedding: imageEmb ?? [],
                            faceCount: s.faceCount,
                            referenceEmbeddings: referenceEmbeddings,
                            avgEmbedding: avg,
                            profile: profile
                        )
                    }

                    if let promptEmb = promptEmbedding, let imageEmb, needsCLIP {
                        s.promptScore = CLIPEmbedder.cosineSimilarity(imageEmb, promptEmb)
                    }

                    if let imageEmb, !precomputedNegativeEmbs.isEmpty {
                        let maxNeg = precomputedNegativeEmbs.map { CLIPEmbedder.cosineSimilarity(imageEmb, $0) }.max() ?? 0
                        s.negativeScore = maxNeg
                    }

                    if let imageEmb, let trendEmb = precomputedTrendEmb {
                        s.trendScore = CLIPEmbedder.cosineSimilarity(imageEmb, trendEmb)
                    }

                    if hasFeedback, let imageEmb {
                        var feedbackScore: Float = 0.5

                        func weightedSim(_ entries: [WeightedEmbedding]) -> Float {
                            var weightedSum: Float = 0; var totalWeight: Float = 0
                            for entry in entries {
                                let w = recencyWeight(entry.date) * max(0.1, min(entry.signal, 1.0))
                                weightedSum += CLIPEmbedder.cosineSimilarity(imageEmb, entry.embedding) * w
                                totalWeight += w
                            }
                            return totalWeight > 0 ? weightedSum / totalWeight : 0
                        }

                        // Positive and negative paths are now symmetric:
                        // Max positive contribution: +0.30 (liked)
                        // Max negative contribution: -0.30 (low-rated) - 0.10 (reason) - 0.08 (contrast) = -0.48
                        // Previously negatives could reach -0.67, making a single low rating hit harder than two likes.
                        // Reduced low-rating reason and contrast weights so the total negative budget ≈ -0.48 max.
                        if !likedEmbeddings.isEmpty  { feedbackScore += weightedSim(likedEmbeddings)  * 0.30 }
                        if !likedReasonEmbeddings.isEmpty { feedbackScore += weightedSim(likedReasonEmbeddings) * 0.08 }
                        if !neutralEmbeddings.isEmpty {
                            feedbackScore += (0.5 - feedbackScore) * weightedSim(neutralEmbeddings) * 0.15
                        }
                        if !lowRatedEmbeddings.isEmpty      { feedbackScore -= weightedSim(lowRatedEmbeddings)      * 0.30 }
                        if !lowRatingReasonEmbeddings.isEmpty { feedbackScore -= weightedSim(lowRatingReasonEmbeddings) * 0.10 }
                        if !contrastEmbeddings.isEmpty      { feedbackScore -= weightedSim(contrastEmbeddings)      * 0.08 }
                        s.feedbackScore = max(0, min(1, feedbackScore))
                    }

                    await semaphore.release()
                    return (i, s)
                }
            }
            var results = [(Int, PhotoScore)]()
            let total = images.count
            for await r in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results.append(r)
                let completed = results.count
                if !Task.isCancelled, let cb = onProgress {
                    Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        cb(completed, total)
                    }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        // 6. Near-duplicate suppression
        // For each cluster of visually near-identical photos (cosine sim > 0.96),
        // keep only the highest-scored photo. The rest still end up in runner-ups.
        scores = suppressNearDuplicates(scores, category: category, isPromptMode: isPromptMode,
                                        promptText: promptText,
                                        dynamicRefWeight: dynamicRefWeight,
                                        wantsLookingAway: wantsLookingAway,
                                        wantsLookingAtCamera: wantsLookingAtCamera,
                                        hasFaceContent: hasFaceContent,
                                        hasFeedback: hasFeedback,
                                        intent: intent,
                                        isDatingMode: isDatingMode,
                                        datingAudience: datingAudience,
                                        dimHints: dimHints,
                                        learnedWeights: learnedWeights,
                                        learnedPreferredYaw: preferredYaw,
                                        closedEyeTolerance: closedEyeTolerance)

        // 7. Sort
        scores.sort {
            weightedScore($0, category: category, isPromptMode: isPromptMode,
                          promptText: promptText,
                          dynamicRefWeight: dynamicRefWeight,
                          wantsLookingAway: wantsLookingAway,
                          wantsLookingAtCamera: wantsLookingAtCamera,
                          hasFaceContent: hasFaceContent,
                          hasFeedback: hasFeedback,
                          intent: intent,
                          isDatingMode: isDatingMode,
                          datingAudience: datingAudience,
                          dimHints: dimHints,
                          learnedWeights: learnedWeights,
                          learnedPreferredYaw: preferredYaw,
                          closedEyeTolerance: closedEyeTolerance)
            >
            weightedScore($1, category: category, isPromptMode: isPromptMode,
                          promptText: promptText,
                          dynamicRefWeight: dynamicRefWeight,
                          wantsLookingAway: wantsLookingAway,
                          wantsLookingAtCamera: wantsLookingAtCamera,
                          hasFaceContent: hasFaceContent,
                          hasFeedback: hasFeedback,
                          intent: intent,
                          isDatingMode: isDatingMode,
                          datingAudience: datingAudience,
                          dimHints: dimHints,
                          learnedWeights: learnedWeights,
                          learnedPreferredYaw: preferredYaw,
                          closedEyeTolerance: closedEyeTolerance)
        }

        // 8. Bucket into top picks + runner ups + delete candidates
        //    Scene-variety picker: greedily select top picks ensuring each comes from a
        //    distinct scene/moment (CLIP cosine threshold 0.72). Prevents 5 nearly-identical
        //    shots from dominating when the user uploads photos from one continuous moment.
        let sortedScores: [PhotoScore]
        let allNonTopPicks: [PhotoScore]

        func sceneDiversePicks(from pool: [PhotoScore], count: Int) -> (picks: [PhotoScore], rest: [PhotoScore]) {
            var picks: [PhotoScore] = []
            var remaining = pool
            var pickedEmbeddings: [[Float]] = []

            while picks.count < count && !remaining.isEmpty {
                // Find highest-scored candidate that is not too similar to already-picked scenes
                var bestIdx: Int? = nil
                for (i, candidate) in remaining.enumerated() {
                    let tooSimilar = pickedEmbeddings.contains { picked in
                        guard let emb = candidate.clipEmbedding else { return false }
                        return CLIPEmbedder.cosineSimilarity(emb, picked) > 0.72
                    }
                    if !tooSimilar { bestIdx = i; break }
                }
                // If every remaining candidate is scene-similar to picked ones, just take the top
                let idx = bestIdx ?? 0
                let chosen = remaining.remove(at: idx)
                picks.append(chosen)
                if let emb = chosen.clipEmbedding { pickedEmbeddings.append(emb) }
            }
            return (picks, remaining)
        }

        // When requireUniquePicks is false, skip scene-diversity logic — just take top N by score
        func simplePicks(from pool: [PhotoScore], count: Int) -> (picks: [PhotoScore], rest: [PhotoScore]) {
            let picks = Array(pool.prefix(count))
            let rest  = Array(pool.dropFirst(count))
            return (picks, rest)
        }
        let picker = requireUniquePicks ? sceneDiversePicks : simplePicks

        if category == .nature && !isPromptMode {
            let noFace   = scores.filter { !$0.hasFace }
            let withFace = scores.filter {  $0.hasFace }
            if noFace.count >= pickCount {
                let (picks, rest) = picker(noFace, pickCount)
                sortedScores   = picks
                allNonTopPicks = rest + withFace
            } else {
                let (picks, rest) = picker(scores, pickCount)
                sortedScores   = picks
                allNonTopPicks = rest
            }
        } else {
            let (picks, rest) = picker(scores, pickCount)
            sortedScores   = picks
            allNonTopPicks = rest
        }

        // Separate objectively bad photos from normal runner-ups
        // Use reference sharpness preference: if user's refs are soft/dreamy, don't flag blur
        let refPrefersSharp = tasteProfile.map { $0.avgSharpness > 0.45 } ?? true
        let objectiveDeleteScores = allNonTopPicks.filter {
            isDeleteCandidate($0, intent: intent, refPrefersSharp: refPrefersSharp, closedEyeTolerance: closedEyeTolerance)
        }
        let deleteScores: [PhotoScore]
        if shouldUseCleanupFallbackDeleteCandidates(
            purposeTag: purposeTag,
            nonTopPickCount: allNonTopPicks.count,
            objectiveDeleteCount: objectiveDeleteScores.count
        ) {
            let fallbackCount = min(min(max(3, scores.count / 20), 12), allNonTopPicks.count)
            deleteScores = cleanupFallbackDeleteCandidates(from: allNonTopPicks, maxCount: fallbackCount, closedEyeTolerance: closedEyeTolerance)
        } else {
            deleteScores = objectiveDeleteScores
        }
        let deletedOriginalIndices = Set(deleteScores.map { $0.originalIndex })

        // Similar photos: tagged by near-duplicate detection, not delete candidates
        let similarScores = allNonTopPicks.filter {
            $0.isSimilar && !deletedOriginalIndices.contains($0.originalIndex)
        }
        let similarOriginalIndices = Set(similarScores.map { $0.originalIndex })

        // Runner-ups: everything else (neither delete candidates nor similar)
        let runnerScores = Array(allNonTopPicks
            .filter {
                !deletedOriginalIndices.contains($0.originalIndex) &&
                !similarOriginalIndices.contains($0.originalIndex)
            }
            .prefix(pickCount * 3))

        // Compute composite scores for all photos and stretch them across a wider range.
        // Raw weightedScore values often cluster in a narrow band (e.g. 0.65–0.72), making
        // every photo feel equally scored. Rank-normalized scores spread the top photo to ~0.92
        // and the bottom to ~0.30 so relative differences are visible.
        let allScores = scores
        let rawValues = allScores.map {
            weightedScore($0, category: category, isPromptMode: isPromptMode,
                          promptText: promptText, dynamicRefWeight: dynamicRefWeight,
                          wantsLookingAway: wantsLookingAway, wantsLookingAtCamera: wantsLookingAtCamera,
                          hasFaceContent: hasFaceContent, hasFeedback: hasFeedback,
                          intent: intent, isDatingMode: isDatingMode, datingAudience: datingAudience,
                          dimHints: dimHints, learnedWeights: learnedWeights,
                          learnedPreferredYaw: preferredYaw,
                          closedEyeTolerance: closedEyeTolerance)
        }
        let rawMin = rawValues.min() ?? 0
        let rawMax = rawValues.max() ?? 1
        let rawRange = rawMax - rawMin
        func normalizedComposite(for photoScore: PhotoScore) -> Float {
            guard let idx = allScores.firstIndex(where: { $0.originalIndex == photoScore.originalIndex }) else { return 0.5 }
            let raw = rawValues[idx]
            guard rawRange > 0.001 else { return 0.60 }
            // Stretch to [0.30, 0.92]
            return 0.30 + ((raw - rawMin) / rawRange) * 0.62
        }

        func makeResult(_ score: PhotoScore, isTopPick: Bool = false) -> PhotoResult {
            let assetId = score.originalIndex < assetIdentifiers.count
                          ? assetIdentifiers[score.originalIndex] : ""
            var result = PhotoResult(
                image: score.image,
                reasoning: buildReasoning(score, isTopPick: isTopPick, isPromptMode: isPromptMode,
                                          promptText: promptText, category: category,
                                          aesthetics: aesthetics,
                                          intent: intent, isDatingMode: isDatingMode,
                                          datingVibe: datingVibe, datingAudience: datingAudience,
                                          purposeTag: purposeTag, isReferenceDriven: isReferenceDriven,
                                          closedEyeTolerance: closedEyeTolerance),
                assetIdentifier: assetId,
                qualityScore: score.qualityScore,
                exposureScore: score.exposureScore,
                compositionScore: score.compositionScore,
                genuineSmileScore: score.genuineSmileScore,
                hasFace: score.hasFace,
                eyeState: score.eyeState,
                eyeOpenConfidence: score.eyeOpenConfidence,
                faceYaw: score.faceYaw,
                colorHarmonyScore: score.colorHarmonyScore,
                userFaceIdentified: score.userFaceIdentified,
                userFaceMatchConfidence: score.userFaceMatchConfidence,
                promptScore: score.promptScore,
                referenceScore: score.referenceScore,
                feedbackScore: score.feedbackScore,
                category: category.rawValue,
                aesthetic: aesthetics.map(\.rawValue).joined(separator: ", "),
                promptText: promptText,
                isPromptMode: isPromptMode
            )
            result.compositeScore = normalizedComposite(for: score)
            return result
        }

        return (
            sortedScores.map  { makeResult($0, isTopPick: true) },
            runnerScores.map  { makeResult($0) },
            deleteScores.map  { makeResult($0) },
            similarScores.map { makeResult($0) }
        )
    }

    // MARK: - Near-duplicate suppression

    /// Clusters photos by CLIP cosine similarity. Within each cluster, marks all but the
    /// highest-scored photo as "suppressed" so they don't appear in top picks — but they
    /// remain in the array so they can still be offered as runner-ups.
    func suppressNearDuplicates(
        _ scores: [PhotoScore],
        category: PhotoCategory,
        isPromptMode: Bool,
        promptText: String = "",
        dynamicRefWeight: Float,
        wantsLookingAway: Bool,
        wantsLookingAtCamera: Bool,
        hasFaceContent: Bool = true,
        hasFeedback: Bool,
        intent: PromptIntent? = nil,
        isDatingMode: Bool = false,
        datingAudience: String = "",
        dimHints: [String: Float] = [:],
        learnedWeights: [String: Float] = [:],
        learnedPreferredYaw: Float? = nil,
        closedEyeTolerance: Float = 0
    ) -> [PhotoScore] {
        guard scores.count > 1 else { return scores }

        // Build a score value for each photo so we can pick the best from a cluster
        let values: [Float] = scores.map {
            weightedScore($0, category: category, isPromptMode: isPromptMode,
                          promptText: promptText,
                          dynamicRefWeight: dynamicRefWeight,
                          wantsLookingAway: wantsLookingAway,
                          wantsLookingAtCamera: wantsLookingAtCamera,
                          hasFaceContent: hasFaceContent,
                          hasFeedback: hasFeedback,
                          intent: intent,
                          isDatingMode: isDatingMode,
                          datingAudience: datingAudience,
                          dimHints: dimHints,
                          learnedWeights: learnedWeights,
                          learnedPreferredYaw: learnedPreferredYaw,
                          closedEyeTolerance: closedEyeTolerance)
        }

        // Greedy clustering: iterate through photos; assign to an existing cluster if
        // cosine similarity to the cluster's representative > threshold, else start new cluster.
        // 0.78 catches burst shots and same-pose variants while allowing different moments to compete.
        let threshold: Float = 0.78
        var clusterRep: [Int] = []       // index of representative for each cluster
        var photoCluster: [Int] = Array(repeating: -1, count: scores.count)

        for i in scores.indices {
            guard let emb = scores[i].clipEmbedding else {
                // No embedding — treat as its own cluster
                let c = clusterRep.count
                clusterRep.append(i)
                photoCluster[i] = c
                continue
            }
            var assigned = false
            for (c, rep) in clusterRep.enumerated() {
                if let repEmb = scores[rep].clipEmbedding {
                    if CLIPEmbedder.cosineSimilarity(emb, repEmb) >= threshold {
                        photoCluster[i] = c
                        assigned = true
                        break
                    }
                }
            }
            if !assigned {
                let c = clusterRep.count
                clusterRep.append(i)
                photoCluster[i] = c
            }
        }

        // For each cluster, find the best-scoring member
        var clusterBest: [Int: Int] = [:]   // cluster → index of best photo
        for i in scores.indices {
            let c = photoCluster[i]
            if let best = clusterBest[c] {
                if values[i] > values[best] { clusterBest[c] = i }
            } else {
                clusterBest[c] = i
            }
        }

        let bestIndices = Set(clusterBest.values)

        // Tag non-best cluster members as similar, then return best-first order.
        // (Similar photos get their own results section instead of polluting runner-ups.)
        var tagged = scores
        for i in tagged.indices where !bestIndices.contains(i) {
            tagged[i].isSimilar = true
        }

        let kept       = tagged.enumerated().filter {  bestIndices.contains($0.offset) }.map { $0.element }
        let suppressed = tagged.enumerated().filter { !bestIndices.contains($0.offset) }.map { $0.element }
        return kept + suppressed
    }

    // MARK: - User face identification

    /// Face-crop CLIP is a proxy for identity, not a dedicated face-recognition model, so the
    /// acceptance gates intentionally favor precision over recall. A missed match falls back to
    /// dominant-face scoring; a false match re-anchors eyes/smile/quality to the wrong person.
    private static let multiFaceMatchFloor: Float = 0.72
    private static let singleReferenceMultiFaceFloor: Float = 0.78
    private static let multiFaceClearMargin: Float = 0.06
    private static let singleReferenceClearMargin: Float = 0.08
    private static let soloFaceMatchFloor: Float = 0.78

    private struct UserFaceMatch {
        let index: Int
        let similarity: Float
        let margin: Float
        let confidence: Float

        init(index: Int, similarity: Float, margin: Float) {
            self.index = index
            self.similarity = similarity
            self.margin = margin
            // Blend absolute similarity and separation from the runner-up. Margin saturates at
            // 0.15 because CLIP face-crop distances are usually compressed.
            let marginScore = min(max(margin / 0.15, 0), 1)
            self.confidence = min(max(similarity * 0.75 + marginScore * 0.25, 0), 1)
        }
    }

    /// Crops the given face (with padding), embeds it via CLIP, and returns its blended similarity
    /// to the user's faceprint. The faceprint can hold several angles of the user, so we blend the
    /// best-matching angle (max — handles the user being shot from a different angle than this photo)
    /// with overall consistency (avg), max-heavy so one good angle isn't diluted. Returns nil when
    /// cropping or embedding fails.
    private func userFaceSimilarity(
        _ face: CandidateFaceData,
        in image: UIImage,
        userFaceEmbeddings: [[Float]]
    ) async -> Float? {
        guard let cgImage = image.cgImage,
              let clipEmbedder = CLIPEmbedder.shared else { return nil }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let pad: CGFloat = 0.30
        let box = face.boundingBox
        let flippedY = 1.0 - box.maxY
        let cropRect = CGRect(
            x: max(0, (box.minX - box.width * pad) * w),
            y: max(0, (flippedY - box.height * pad) * h),
            width: min(w, box.width * (1 + 2 * pad) * w),
            height: min(h, box.height * (1 + 2 * pad) * h)
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))

        guard cropRect.width > 20, cropRect.height > 20,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }
        guard let faceEmb = await clipEmbedder.embedAsync(image: UIImage(cgImage: cropped)) else { return nil }

        let perRef = userFaceEmbeddings.map { CLIPEmbedder.cosineSimilarity(faceEmb, $0) }
        let maxSim = perRef.max() ?? 0
        let avgSim = perRef.reduce(0, +) / Float(perRef.count)
        return maxSim * 0.65 + avgSim * 0.35
    }

    /// Confirms whether a solo photo's single face belongs to the user. Used so that selfies (one
    /// face) can still set `userFaceIdentified` — without this, angle/expression learning only ever
    /// triggers on multi-face group shots. With no competing face to create a margin, the absolute
    /// floor is intentionally stricter than multi-face matching.
    private func soloFaceMatchConfidence(
        _ face: CandidateFaceData,
        in image: UIImage,
        userFaceEmbeddings: [[Float]]
    ) async -> Float? {
        guard !userFaceEmbeddings.isEmpty else { return nil }
        guard let sim = await userFaceSimilarity(face, in: image, userFaceEmbeddings: userFaceEmbeddings),
              sim >= BatchProcessor.soloFaceMatchFloor else { return nil }
        return sim
    }

    /// Identifies which candidate face belongs to the user by comparing CLIP face-crop embeddings
    /// against the user's reference face embeddings. Returns the index into `candidates` (sorted
    /// largest first) of the user's face, or nil when identification is ambiguous or unnecessary.
    ///
    /// No area gate: the user is whoever MATCHES their reference faceprint, regardless of how big
    /// they are in frame — a user standing behind a taller stranger must still be found. False
    /// matches are guarded by an absolute similarity floor plus a clear-winner margin. Requires CLIP
    /// and at least two candidate faces (single-face photos go through `soloFaceMatchConfidence`).
    private func identifyUserFace(
        in image: UIImage,
        candidates: [CandidateFaceData],
        userFaceEmbeddings: [[Float]]
    ) async -> UserFaceMatch? {
        guard !userFaceEmbeddings.isEmpty, candidates.count > 1 else { return nil }

        var sims: [(index: Int, sim: Float)] = []
        for (i, face) in candidates.enumerated() {
            if let sim = await userFaceSimilarity(face, in: image, userFaceEmbeddings: userFaceEmbeddings) {
                sims.append((index: i, sim: sim))
            }
        }

        guard let best = sims.max(by: { $0.sim < $1.sim }) else { return nil }
        let secondBest = sims.filter { $0.index != best.index }.max(by: { $0.sim < $1.sim })
        let margin = best.sim - (secondBest?.sim ?? 0)

        // Absolute floor: the best face must actually resemble the user's faceprint. Without this,
        // the lack of an area gate would make us always pick *some* face even when the user isn't in
        // the photo at all — better to fall back to the dominant face than override with a stranger.
        let floor = userFaceEmbeddings.count >= 2
            ? BatchProcessor.multiFaceMatchFloor
            : BatchProcessor.singleReferenceMultiFaceFloor
        if best.sim < floor { return nil }

        // Only accept a clear winner — a small margin means two faces match the user's faceprint
        // about equally (e.g. a sibling), so we can't safely say which one is the user.
        let requiredMargin = userFaceEmbeddings.count >= 2
            ? BatchProcessor.multiFaceClearMargin
            : BatchProcessor.singleReferenceClearMargin
        if margin < requiredMargin { return nil }

        return UserFaceMatch(index: best.index, similarity: best.sim, margin: margin)
    }

    // MARK: - Outfit contrast

    /// Estimates how well the subject's outfit contrasts against the background.
    /// Returns 0–1 where 1 = strong pop/contrast, 0.5 = neutral, 0 = blends in.
    func outfitContrastScore(image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let ciImage = CIImage(cgImage: cgImage)
        let ctx = SharedCIContext.shared

        func avgRGB(rect: CGRect) -> (r: Float, g: Float, b: Float)? {
            guard let filter = CIFilter(name: "CIAreaAverage",
                  parameters: [kCIInputImageKey: ciImage,
                               kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let output = filter.outputImage else { return nil }
            var pixel = [Float](repeating: 0, count: 4)
            ctx.render(output, toBitmap: &pixel,
                       rowBytes: 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (pixel[0], pixel[1], pixel[2])
        }

        // Centre strip (subject / clothing area): middle 40% × 60%
        let subRect = CGRect(x: w * 0.30, y: h * 0.20, width: w * 0.40, height: h * 0.60)
        let side = min(w, h) * 0.18
        let corners = [
            CGRect(x: 0, y: 0, width: side, height: side),
            CGRect(x: w - side, y: 0, width: side, height: side),
            CGRect(x: 0, y: h - side, width: side, height: side),
            CGRect(x: w - side, y: h - side, width: side, height: side),
        ]

        guard let sub = avgRGB(rect: subRect) else { return 0.5 }
        let bgSamples = corners.compactMap { avgRGB(rect: $0) }
        guard !bgSamples.isEmpty else { return 0.5 }

        let bgR = bgSamples.map(\.r).reduce(0, +) / Float(bgSamples.count)
        let bgG = bgSamples.map(\.g).reduce(0, +) / Float(bgSamples.count)
        let bgB = bgSamples.map(\.b).reduce(0, +) / Float(bgSamples.count)

        let dr = sub.r - bgR; let dg = sub.g - bgG; let db = sub.b - bgB
        let dist = sqrt(dr*dr + dg*dg + db*db)
        return min(dist / 1.73 * 2.2, 1.0)
    }

    // MARK: - Gaze intent detection

    func promptWantsLookingAway(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["looking away", "not looking", "look away", "averted", "off camera",
                "gazing away", "staring away", "eyes away", "away from camera"]
            .contains { lower.contains($0) }
    }

    func promptWantsLookingAtCamera(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["looking at camera", "eye contact", "direct gaze", "staring at camera",
                "facing camera", "looking into camera"]
            .contains { lower.contains($0) }
    }

    func promptWantsEyesClosed(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["eyes closed", "closing eyes", "closed eyes", "dreamy", "sleepy"]
            .contains { lower.contains($0) }
    }

    func promptWantsBlurry(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["soft focus", "bokeh", "hazy", "dreamy", "blurry background",
                "blur", "out of focus", "unfocused", "motion blur", "ethereal"]
            .contains { lower.contains($0) }
    }

    func promptWantsDark(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["dark", "moody", "night", "silhouette", "shadow", "low light",
                "dimly lit", "underexposed", "dramatic shadows"]
            .contains { lower.contains($0) }
    }

    func promptWantsMotion(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["motion", "action", "movement", "dynamic", "blur", "speed",
                "sports", "dancing", "jumping"]
            .contains { lower.contains($0) }
    }

    func promptWantsHighKey(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["overexposed", "washed out", "high key", "blown out", "bleached",
                "bright white", "airy and bright", "light and airy"]
            .contains { lower.contains($0) }
    }

    /// Awkward, funny, candid, unposed — suppress pose penalty and flip scoring
    func promptWantsAwkward(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["awkward", "funny", "goofy", "silly", "hilarious", "comedic",
                "humorous", "candid", "unposed", "spontaneous", "weird",
                "derpy", "laugh", "laughing", "bloopers", "outtake"]
            .contains { lower.contains($0) }
    }

    /// Serious / stoic — flip smile bonus so non-smiling photos rank higher
    func promptWantsSerious(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["serious", "stoic", "no smile", "straight face", "stern",
                "neutral expression", "expressionless", "deadpan", "intense",
                "brooding", "cold", "fierce", "strong"]
            .contains { lower.contains($0) }
    }

    /// Intentionally imperfect aesthetic — suppress negative CLIP penalty
    func promptWantsImperfect(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["grain", "grainy", "film grain", "vintage", "retro", "analog",
                "lo-fi", "imperfect", "polaroid", "old photo", "authentic",
                "raw and real", "unfiltered", "disposable", "film camera",
                "kodak", "fuji", "lomography"]
            .contains { lower.contains($0) }
    }

    /// True when the user wants a tall / statuesque / full-body composition.
    /// Gates the `subjectHeight` contribution in `weightedScore` — we don't want
    /// to nudge headshots downward for the sake of full-body-ness by default.
    func promptWantsTallSubject(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["tall", "full body", "full-body", "head to toe", "head-to-toe",
                "statuesque", "make me look tall", "makes me look tall",
                "looking tall", "elongated", "leggy"]
            .contains { lower.contains($0) }
    }

    /// Returns true when the prompt explicitly involves people, faces, or portraits.
    /// When false in prompt mode, eye/gaze penalties are suppressed so food, animal,
    /// landscape, and object photos aren't unfairly penalised for incidental faces.
    func promptHasFaceContent(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["person", "people", "face", "faces", "portrait", "selfie", "human",
                "girl", "boy", "man", "woman", "friend", "friends", "family", "couple",
                "group", "crowd", "smile", "eyes", "looking", "gaze", "expression",
                "pose", "posing", "model", "subject", "headshot", "me", "us"]
            .contains { lower.contains($0) }
    }

    func isDeleteCandidate(
        _ score: PhotoScore,
        intent: PromptIntent,
        refPrefersSharp: Bool,
        closedEyeTolerance: Float = 0
    ) -> Bool {
        // Blurry / very low quality
        // Skip if the user explicitly asked for something that tolerates blur or imperfection
        if score.qualityScore < 0.20 {
            if intent.wantsBlurry || intent.wantsMotion || intent.wantsImperfect || !refPrefersSharp { return false }
            return true
        }

        // Eyes clearly closed (high confidence)
        // Skip if user asked for closed eyes, a candid/awkward/dreamy look, or non-face content
        // Closed-eye delete candidate: require a definite `.closed` verdict AND low confidence.
        // Without the state check, `.unknown` readings (sunglasses, profile) at confidence 0.5
        // wouldn't be flagged anyway — but adding the state gate guards against future
        // regressions where a 0.18 confidence could come from an unreliable reading.
        if score.hasFace && score.eyeState == .closed && score.eyeOpenConfidence < 0.20 {
            if intent.wantsEyesClosed || intent.wantsBlurry || intent.wantsAwkward
               || !intent.hasFaceContent { return false }
            if closedEyePenaltyRelief(for: score, tolerance: closedEyeTolerance) > 0.35 {
                return false
            }
            return true
        }

        // Awkward / unnatural body pose — only flag in non-prompted or face-focused mode
        if score.hasFace && score.poseScore < 0.25 {
            if intent.wantsAwkward || !intent.hasFaceContent { return false }
            return true
        }

        // Animal clearly blinking or turned away
        if score.hasAnimal && !score.hasFace && score.animalEyeConfidence < 0.15 {
            if intent.wantsBlurry || intent.wantsAwkward { return false }
            return true
        }

        return false
    }

    func shouldUseCleanupFallbackDeleteCandidates(
        purposeTag: String,
        nonTopPickCount: Int,
        objectiveDeleteCount: Int
    ) -> Bool {
        objectiveDeleteCount == 0 &&
        nonTopPickCount >= 10 &&
        isCleanupPurposeTag(purposeTag)
    }

    func cleanupFallbackDeleteCandidates(
        from candidates: [PhotoScore],
        maxCount: Int,
        closedEyeTolerance: Float = 0
    ) -> [PhotoScore] {
        guard maxCount > 0 else { return [] }

        return Array(candidates
            .map { ($0, cleanupReviewWeaknessScore($0, closedEyeTolerance: closedEyeTolerance)) }
            .filter { $0.1 > 0 }
            .sorted {
                if abs($0.1 - $1.1) > 0.001 { return $0.1 > $1.1 }
                return $0.0.qualityScore < $1.0.qualityScore
            }
            .prefix(maxCount)
            .map(\.0))
    }

    func cleanupReviewWeaknessScore(_ score: PhotoScore, closedEyeTolerance: Float = 0) -> Float {
        var weakness: Float = 0

        if score.qualityScore < 0.38 {
            weakness += (0.38 - score.qualityScore) * 2.0
        }
        if score.exposureScore < 0.42 {
            weakness += (0.42 - score.exposureScore) * 1.1
        }
        if score.compositionScore < 0.35 {
            weakness += (0.35 - score.compositionScore) * 0.8
        }
        if score.negativeScore > 0.22 {
            weakness += (score.negativeScore - 0.22) * 0.9
        }

        if score.hasFace {
            if score.eyeState == .closed && score.eyeOpenConfidence < 0.35 {
                let relief = closedEyePenaltyRelief(for: score, tolerance: closedEyeTolerance)
                weakness += (0.35 - score.eyeOpenConfidence) * 1.4 * (1.0 - relief)
            }
            if score.poseScore < 0.32 {
                weakness += (0.32 - score.poseScore) * 1.1
            }
        }

        return weakness
    }

    func isCleanupPurposeTag(_ purposeTag: String) -> Bool {
        let lower = purposeTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "cleanup" ||
        lower == BatchPurpose.cleanup.rawValue.lowercased() ||
        lower.contains("clean up") ||
        lower.contains("camera roll")
    }

    // MARK: - Weighted score

    func weightedScore(
        _ score: PhotoScore,
        category: PhotoCategory,
        isPromptMode: Bool,
        promptText: String = "",
        dynamicRefWeight: Float,
        wantsLookingAway: Bool = false,
        wantsLookingAtCamera: Bool = false,
        hasFaceContent: Bool = true,
        hasFeedback: Bool = false,
        intent: PromptIntent? = nil,
        isDatingMode: Bool = false,
        datingAudience: String = "",           // "women", "men", or "everyone" — shifts dating formula weights
        dimHints: [String: Float] = [:],       // F5: low-rating reason -> dimension boost
        learnedWeights: [String: Float] = [:], // F6: per-user learned weight multipliers
        learnedPreferredYaw: Float? = nil,     // learned preferred head angle (radians), nil = unknown
        closedEyeTolerance: Float = 0          // learned user tolerance for intentional closed-eye shots
    ) -> Float {
        let ref = score.referenceScore ?? 0

        // Combine dimHints and learnedWeights multiplicatively so that:
        //   - Low-rating reason hints (always >= 1.0) boost the dimension weight
        //   - Learned weights (can be < 1.0) can also DECREASE it when the user's
        //     high-rated photos consistently score low on that dimension
        // Previously used max(), which silenced learned decreases.
        func dimMult(_ key: String) -> Float {
            // Cap each factor before multiplying so neither alone can saturate the product cap.
            // Without individual caps a hint of 1.25 combined with learned=1.40 → 1.75,
            // which gets hard-clamped to 1.60 and silently ignores part of the signal.
            let hint    = min(dimHints[key] ?? 1.0, 1.30)
            let learned = min(max(learnedWeights[key] ?? 1.0, 0.70), 1.40)
            return min(max(hint * learned, 0.60), 1.60)
        }

        // Unpack intent overrides — each one lifts a default penalty when the user
        // explicitly asked for that quality in their prompt.
        let wantsAwkward    = intent?.wantsAwkward    ?? false
        let wantsSerious    = intent?.wantsSerious    ?? false
        let wantsImperfect  = intent?.wantsImperfect  ?? false
        let wantsHighKey    = intent?.wantsHighKey    ?? false
        let wantsDark       = intent?.wantsDark       ?? false
        let wantsEyesClosed = intent?.wantsEyesClosed ?? false
        let wantsTallSubject = intent?.wantsTallSubject ?? false

        // ── New aesthetic nudges ─────────────────────────────────────────────
        // All three are multiplicative tweaks at the end, kept small so existing
        // category/prompt/dating weightings stay dominant and tests stay stable.

        // Vibe bonus: "slight blur but nice vibes". Always applied.
        // Range: vibe=1.0 → ×1.05, vibe=0.5 → ×1.0, vibe=0.0 → ×0.95.
        let vibeBonus: Float = 1.0 + (score.vibeScore - 0.5) * 0.10

        // Trend bonus: CLIP similarity to the modern-aesthetic centroid.
        // Range: trendScore=1.0 → ×1.03, trendScore=0.5 → ×1.0, trendScore=0.0 → ×0.97.
        // Suppressed in outfit mode (colour/fit already dominate) and when the
        // user explicitly asked for an "imperfect" look (the trend centroid doesn't
        // know about the user's specific aesthetic intent).
        let trendBonus: Float
        if wantsImperfect || isOutfitPrompt(promptText) {
            trendBonus = 1.0
        } else {
            trendBonus = 1.0 + (score.trendScore - 0.5) * 0.06
        }

        // Subject-height bonus — keyword-gated. Only fires when the user
        // explicitly asked for "tall / full body / statuesque". Otherwise
        // ×1.0 so head-and-shoulders portraits are not penalised.
        // When active: subjectHeight=1.0 → ×1.20, 0.5 → ×1.0, 0.0 → ×0.80.
        let subjectHeightBonus: Float = wantsTallSubject
            ? 1.0 + (score.subjectHeight - 0.5) * 0.40
            : 1.0

        // In prompt mode for non-face content (food, animals, landscapes, etc.), any person
        // incidentally in frame shouldn't trigger eye/gaze penalties — those signals are
        // irrelevant when the user asked for "best food photos" or "nature shots".
        let applyFacePenalties = !isPromptMode || hasFaceContent

        // Preferred-yaw bonus — rewards photos whose identified user-face head angle is close to
        // the angle the user has historically liked. Only fires when (a) we've learned a preferred
        // yaw from ≥5 identified self-photos and (b) THIS photo's user face was identified. Small
        // and bounded so it nudges rather than overrides; ×1.0 (neutral) otherwise, keeping tests
        // and non-self photos unaffected.
        let yawBonus: Float
        if let preferredYaw = learnedPreferredYaw, score.userFaceIdentified, applyFacePenalties {
            let delta = abs(abs(score.faceYaw) - abs(preferredYaw))
            // delta 0 → ×1.08, delta ~0.5rad (~29°) → ×1.0, larger → down to a 0.92 floor.
            yawBonus = min(max(1.08 - delta * 0.16, 0.92), 1.08)
        } else {
            yawBonus = 1.0
        }

        // Gaze multiplier — only meaningful when face content is the subject
        var gazeMultiplier: Float = 1.0
        if score.hasFace && applyFacePenalties {
            let isLookingAway = score.faceYaw > 0.25
            if wantsLookingAway {
                gazeMultiplier = isLookingAway ? 1.3 : 0.2
            } else if wantsLookingAtCamera {
                gazeMultiplier = isLookingAway ? 0.3 : 1.2
            }
        }

        // Eye penalty: apply proportionally to eye confidence.
        // Suppressed when the user asked for closed eyes, or for non-face content.
        // `.unknown` (sunglasses / profile / squint / wink) gets a near-neutral 0.92 — a
        // slight uncertainty haircut, but far less than the 0.77 a 0.5-confidence reading
        // used to get under the old eyeOpenConfidence-only formula. This stops sunglasses
        // photos from being falsely promoted or falsely punished.
        //
        // eyeHintMult: if the user's low-rating reason mentioned closed/tired eyes, the penalty
        // for low eye-open confidence is tightened. Open eyes (confidence ≥ 0.85) are
        // unaffected — we don't want to double-reward good eyes, just make bad eyes hurt more.
        let eyeHintMult = dimMult("eyeOpenConfidence")
        let eyePenalty: Float
        if wantsEyesClosed {
            // User wants closed eyes — flip: closed eyes score higher
            if score.eyeState == .unknown {
                eyePenalty = 0.92
            } else {
                eyePenalty = 0.4 + (1.0 - score.eyeOpenConfidence) * 0.6
            }
        } else if score.hasFace && applyFacePenalties {
            if score.eyeState == .unknown {
                eyePenalty = 0.92
            } else {
                let base = 0.55 + score.eyeOpenConfidence * 0.45
                let relief = score.eyeState == .closed
                    ? closedEyePenaltyRelief(for: score, tolerance: closedEyeTolerance)
                    : 0
                let contextualBase = base + (0.92 - base) * relief
                // Always respect explicit closed-eye low rating hints on closed-eye photos.
                if score.eyeState == .closed, eyeHintMult > 1.0 {
                    eyePenalty = max(contextualBase / eyeHintMult, 0.35)
                } else {
                    // Only apply the hint boost when eyes look bad (base < 0.85).
                    // For clearly-open eyes we don't change anything — penalty is already ≥1.0 territory.
                    eyePenalty = contextualBase < 0.85 ? max(contextualBase / eyeHintMult, 0.35) : contextualBase
                }
            }
        } else if score.hasAnimal && applyFacePenalties {
            eyePenalty = 0.6 + score.animalEyeConfidence * 0.4
        } else {
            eyePenalty = 1.0
        }

        // Feedback multiplier
        let feedbackBoost: Float
        if hasFeedback, let fb = score.feedbackScore {
            let rc    = RemoteConfigService.shared
            let range = rc.feedbackBoostMax - rc.feedbackBoostMin
            feedbackBoost = rc.feedbackBoostMin + (fb * range)
        } else {
            feedbackBoost = 1.0
        }

        // Negative CLIP penalty — photos resembling "blurry/overexposed/low quality" get knocked down.
        // Suppressed entirely when the user asked for an intentionally imperfect aesthetic
        // (vintage, film grain, retro, etc.) — in that case "flaws" are part of the style.
        let negativePenalty: Float
        if wantsImperfect {
            negativePenalty = 1.0
        } else {
            negativePenalty = score.negativeScore > 0.20
                ? max(1.0 - (score.negativeScore - 0.20) * 3.0, 0.50)
                : 1.0
        }

        // Exposure quality multiplier.
        // wantsDark: don't penalise underexposed / low-light photos.
        // wantsHighKey: don't penalise overexposed / washed-out photos.
        // wantsImperfect: skip exposure scoring — imperfect look includes exposure oddities.
        //
        // Note: exposureScore is "distance from ideal" (1.0 = well exposed, lower = either
        // blown highlights OR crushed blacks). It can't tell which extreme a low score
        // represents. When the user explicitly asked for a non-standard exposure style
        // we *suppress* the penalty but cap at 0.95 — the same multiplier a well-exposed
        // photo gets under normal scaling — so a truly well-exposed photo is never
        // out-ranked by a stylistically-low-exposure one.
        let exposureMult: Float
        if wantsImperfect {
            exposureMult = 1.0
        } else if (wantsDark && score.exposureScore < 0.5) || (wantsHighKey && score.exposureScore < 0.5) {
            exposureMult = 0.95
        } else if wantsDark || wantsHighKey {
            // Only suppress the penalty on the relevant end; leave the other end alone
            exposureMult = max(0.5 + score.exposureScore * 0.5, 0.85)
        } else {
            exposureMult = 0.5 + score.exposureScore * 0.5
        }

        if isDatingMode, let prompt = score.promptScore {
            // Dating mode scoring: vibe match + strong portrait signals
            // Solo shot bonus — single face is ideal for dating profiles
            let soloBonus: Float
            if score.hasFace {
                soloBonus = score.faceCount == 1 ? 1.20 : (score.faceCount == 2 ? 0.80 : 0.60)
            } else {
                soloBonus = 0.70  // no face at all is weak for dating
            }

            // Audience-specific signal boosts (research-backed dating app preferences):
            // Women audience: genuine warmth and expression matter most
            // Men audience: confidence and body language slightly more valued
            let audienceLower = datingAudience.lowercased()
            let smileAudienceBoost: Float = audienceLower == "women" ? 1.10 : 1.0
            let poseAudienceBoost: Float  = audienceLower == "men"   ? 1.10 : 1.0

            // Genuine smile matters a lot for attraction — Duchenne scores higher than lips-only
            let datingSmile: Float = score.hasFace
                ? (0.90 + score.genuineSmileScore * 0.35 * smileAudienceBoost)
                : 1.0

            // Eye contact — critical for connection in dating photos
            let datingEyeContact: Float
            if score.hasFace {
                let lookingAway = score.faceYaw > 0.20
                datingEyeContact = lookingAway ? 0.85 : 1.15
            } else {
                datingEyeContact = 1.0
            }

            // Pose naturalness — very important for first impressions
            let datingPose: Float
            if score.hasFace && score.poseScore < 0.5 {
                datingPose = (0.70 + score.poseScore * 0.6) * poseAudienceBoost
            } else {
                datingPose = 1.0 * poseAudienceBoost
            }

            // Face size bonus — a face filling the frame matters for dating photos
            let datingFaceSizeBonus: Float
            if score.hasFace, let box = score.faceBoundingBox {
                switch Float(box.width) {
                case 0.30...:        datingFaceSizeBonus = 1.15
                case 0.15..<0.30:    datingFaceSizeBonus = 1.05
                case 0.06..<0.15:    datingFaceSizeBonus = 0.90
                default:             datingFaceSizeBonus = 0.75
                }
            } else {
                datingFaceSizeBonus = 1.0
            }

            // BUG FIX: Weight allocation now sums to 1.0 regardless of reference presence.
            // Previously: vibeWeight * remaining + qualityWeight * remaining + refWeight2
            // could leave 35% of the budget unaccounted when refs were absent because
            // remaining = 1.0 but vibeWeight + qualityWeight = 0.65.
            let vibeWeight: Float = 0.35
            let qualityWeight: Float = 0.30
            let refWeight2: Float = dynamicRefWeight > 0 ? dynamicRefWeight : 0
            let remaining = 1.0 - refWeight2
            // Distribute remaining budget across vibe, quality, and face signal weights
            let base = (prompt * vibeWeight * remaining)
                     + (score.qualityScore * qualityWeight * remaining)
                     + (ref * refWeight2)
            // Apply learned exposure preference in dating mode too
            let learnedExposureMult = dimMult("exposureScore")
            let datingRaw = min(base * soloBonus * datingSmile * datingEyeContact * datingPose * datingFaceSizeBonus, 1.0)
                * eyePenalty * feedbackBoost * negativePenalty * (exposureMult * learnedExposureMult)
                * vibeBonus * trendBonus * subjectHeightBonus * yawBonus
            return min(max(datingRaw.isFinite ? datingRaw : 0.0, 0.0), 1.0)
        }

        if isPromptMode, let prompt = score.promptScore {
            let rc  = RemoteConfigService.shared
            let pw  = rc.promptWeight
            let qw  = 1.0 - pw
            let outfitMode = isOutfitPrompt(promptText)
            let base: Float
            if dynamicRefWeight > 0 {
                let pw2 = pw * (1.0 - dynamicRefWeight)
                let qw2 = qw * (1.0 - dynamicRefWeight)
                base = (prompt * pw2) + (ref * dynamicRefWeight) + (score.qualityScore * qw2)
            } else if outfitMode {
                // Outfit mode: color harmony is the primary visual signal — blend it in
                // at the expense of raw quality score.
                let harmonyW: Float = 0.12
                let qw2 = max(qw - harmonyW, 0)
                base = (prompt * pw)
                     + (score.qualityScore     * qw2)
                     + (score.colorHarmonyScore * harmonyW * dimMult("colorHarmonyScore"))
            } else {
                base = (prompt * pw) + (score.qualityScore * qw)
            }

            // Pose + smile multipliers — applied when the prompt is face-relevant.
            // Previously only category mode had these; prompt mode skipped them entirely,
            // so "headshot" or "portrait" prompts ignored pose and expression quality.
            let promptPoseMult: Float
            let promptSmileMult: Float
            if hasFaceContent && score.hasFace {
                promptPoseMult = score.poseScore < 0.5
                    ? (wantsAwkward ? 1.0 : 0.75 + score.poseScore * 0.5)
                    : 1.0
                if wantsSerious {
                    promptSmileMult = 1.20 - score.genuineSmileScore * 0.40
                } else if wantsAwkward {
                    promptSmileMult = 1.0
                } else {
                    promptSmileMult = 0.90 + score.genuineSmileScore * 0.25
                }
            } else {
                promptPoseMult = 1.0
                promptSmileMult = 1.0
            }

            // Apply learned exposure preference in prompt mode too
            let learnedExposureMult = dimMult("exposureScore")
            let promptRaw = base * eyePenalty * gazeMultiplier * feedbackBoost * negativePenalty
                * (exposureMult * learnedExposureMult) * promptPoseMult * promptSmileMult
                * vibeBonus * trendBonus * subjectHeightBonus * yawBonus
            return min(max(promptRaw.isFinite ? promptRaw : 0.0, 0.0), 1.0)
        }

        let scale = 1.0 - dynamicRefWeight

        // Face size bonus for portrait-focused categories: a face filling the frame scores higher
        let faceSizeBonus: Float
        if score.hasFace, let box = score.faceBoundingBox {
            switch Float(box.width) {
            case 0.30...:        faceSizeBonus = 1.20
            case 0.15..<0.30:    faceSizeBonus = 1.05
            case 0.06..<0.15:    faceSizeBonus = 0.85
            default:             faceSizeBonus = 0.70  // face too tiny for a portrait
            }
        } else {
            faceSizeBonus = 1.0
        }

        // Bokeh bonus: sharp subject + blurry background — only meaningful for portrait/mugshot
        let bokehBonus: Float
        if score.hasFace {
            let separation = score.qualityScore - score.backgroundSharpness
            bokehBonus = separation > 0.35 ? 1.15 : (separation > 0.15 ? 1.07 : 1.0)
        } else {
            bokehBonus = 1.0
        }

        // Pose naturalness multiplier.
        // wantsAwkward: user asked for funny/candid/goofy — awkward poses are desirable, skip penalty.
        // Otherwise: penalise turned-away or very poorly-detected body stances.
        let poseMult: Float
        if !score.hasFace || wantsAwkward {
            poseMult = 1.0
        } else if score.poseScore < 0.5 {
            poseMult = 0.75 + score.poseScore * 0.5
        } else {
            poseMult = 1.0
        }

        let base: Float
        switch category {
        case .mugshot:
            let smileBonus: Float
            if wantsSerious {
                smileBonus = 1.20 - score.genuineSmileScore * 0.40 * dimMult("genuineSmileScore")
            } else if wantsAwkward {
                smileBonus = 1.0
            } else {
                smileBonus = 0.85 + score.genuineSmileScore * 0.40 * dimMult("genuineSmileScore")
            }
            let raw = (score.qualityScore      * 0.41 * dimMult("qualityScore"))
                    + (score.categoryScore     * 0.18)
                    + (score.aestheticScore    * 0.14)
                    + (score.compositionScore  * 0.20 * dimMult("compositionScore"))
                    + (score.colorHarmonyScore * 0.07 * dimMult("colorHarmonyScore"))
            base = min(raw * smileBonus * faceSizeBonus * bokehBonus * poseMult, 1.0)

        case .nature:
            // Face penalty: gentle nudge so a landscape with a tiny person isn't destroyed.
            // 0.2 was far too harsh (80% reduction); 0.70 gives a 30% nudge toward no-face shots
            // while still allowing great photos with incidental people to rank well.
            let facePenalty: Float = score.hasFace ? 0.70 : 1.0
            let raw = (score.qualityScore      * 0.12 * dimMult("qualityScore"))
                    + (score.categoryScore     * 0.58)
                    + (score.aestheticScore    * 0.18)
                    + (score.colorHarmonyScore * 0.12 * dimMult("colorHarmonyScore"))
            base = raw * facePenalty

        case .vacation:
            let compBonus: Float = score.hasFace ? (0.8 + score.compositionScore * 0.2 * dimMult("compositionScore")) : 1.0
            let raw = (score.qualityScore      * 0.27 * dimMult("qualityScore"))
                    + (score.categoryScore     * 0.36)
                    + (score.aestheticScore    * 0.27)
                    + (score.colorHarmonyScore * 0.10 * dimMult("colorHarmonyScore"))
            base = raw * compBonus * poseMult

        case .concert:
            let raw = (score.qualityScore      * 0.18 * dimMult("qualityScore"))
                    + (score.categoryScore     * 0.40)
                    + (score.aestheticScore    * 0.30)
                    + (score.colorHarmonyScore * 0.12 * dimMult("colorHarmonyScore"))
            base = raw

        case .edgy:
            let smilePenalty: Float = score.hasFace
                ? max(1.0 - score.genuineSmileScore * 0.75, 0.25)
                : 1.0
            let raw = (score.qualityScore      * 0.12 * dimMult("qualityScore"))
                    + (score.categoryScore     * 0.27)
                    + (score.aestheticScore    * 0.49)
                    + (score.colorHarmonyScore * 0.12 * dimMult("colorHarmonyScore"))
            base = raw * smilePenalty
        }

        // Apply learned exposure multiplier on top of existing exposureMult
        let learnedExposureMult = dimMult("exposureScore")
        let combined = ((base * scale) + (ref * dynamicRefWeight))
               * eyePenalty * gazeMultiplier * feedbackBoost * negativePenalty
               * (exposureMult * learnedExposureMult)
               * vibeBonus * trendBonus * subjectHeightBonus * yawBonus
        // NaN/Inf guard: if any component produced NaN (e.g. division by zero in normalization),
        // return 0.0 so the sort doesn't crash or randomize results.
        return min(max(combined.isFinite ? combined : 0.0, 0.0), 1.0)
    }

    // MARK: - Phrase variation helper

    /// Picks deterministically from a phrase pool using the photo's original index.
    /// Same photo always gets the same variant; adjacent photos in the batch get different words.
    private func pick<T>(_ pool: [T], for score: PhotoScore) -> T {
        pool[abs(score.originalIndex) % pool.count]
    }

    // MARK: - Reasoning (top picks only — runner-ups and similar photos get no reasoning)

    func buildReasoning(_ score: PhotoScore, isTopPick: Bool, isPromptMode: Bool, promptText: String,
                        category: PhotoCategory, aesthetics: [AestheticStyle] = [], intent: PromptIntent? = nil,
                        isDatingMode: Bool = false, datingVibe: String = "", datingAudience: String = "",
                        purposeTag: String = "", isReferenceDriven: Bool = false,
                        closedEyeTolerance: Float = 0) -> String {
        guard isTopPick else {
            // Runner-up: 3-4 signal bullets, sorted by strength
            struct RUSignal { let text: String; let weight: Float }
            var sigs: [RUSignal] = []

            // Quality
            if score.qualityScore > 0.78 {
                sigs.append(RUSignal(text: pick(["Sharp and well-exposed", "Clean, well-lit shot", "Good technical quality"], for: score), weight: score.qualityScore))
            } else if score.qualityScore > 0.55 {
                sigs.append(RUSignal(text: pick(["Decent photo quality", "Solid technical quality", "Reasonably sharp and lit"], for: score), weight: score.qualityScore))
            } else {
                sigs.append(RUSignal(text: pick(["Soft or underexposed — didn't make top picks", "Quality held it back slightly", "Could be sharper or better lit"], for: score), weight: score.qualityScore))
            }

            // Face signals
            if score.hasFace {
                if score.genuineSmileScore > 0.65 {
                    sigs.append(RUSignal(text: pick(["Good natural expression", "Warm, genuine expression", "Nice smile — authentic moment"], for: score), weight: score.genuineSmileScore))
                } else if score.eyeState == .open && score.eyeOpenConfidence > 0.70 {
                    sigs.append(RUSignal(text: pick(["Eyes look open and sharp", "Clear, engaging eye contact", "Eyes look open — sharp focus"], for: score), weight: score.eyeOpenConfidence))
                } else if score.poseScore > 0.72 {
                    sigs.append(RUSignal(text: pick(["Natural, relaxed pose", "Good body language", "Comfortable and natural posture"], for: score), weight: score.poseScore))
                } else if score.eyeState == .closed && closedEyePenaltyRelief(for: score, tolerance: closedEyeTolerance) > 0.35 {
                    sigs.append(RUSignal(text: pick(["Closed-eye expression still works here", "Intentional closed-eye moment", "Strong expression offsets closed eyes"], for: score), weight: closedEyeContextScore(score)))
                } else if score.eyeState == .closed {
                    sigs.append(RUSignal(text: pick(["Eyes may be closed or mid-blink", "Blink or squint hurt the score", "Eyes partly closed — didn't make top picks"], for: score), weight: 0.2))
                } else if score.eyeState == .unknown {
                    sigs.append(RUSignal(text: "Eye state uncertain — worth checking manually", weight: 0.18))
                }
            }

            // Reference / prompt match
            if let rs = score.referenceScore, rs > 0.52 {
                sigs.append(RUSignal(text: pick(["Matches your reference photo style", "Style aligns with your references", "Consistent with your reference look"], for: score), weight: rs))
            } else if let ps = score.promptScore, ps > 0.22 {
                sigs.append(RUSignal(text: pick(["Decent content match for your prompt", "Relevant to what you're looking for", "Matches the prompt reasonably well"], for: score), weight: ps))
            }

            // Exposure / composition tiebreaker
            if score.exposureScore > 0.78 {
                sigs.append(RUSignal(text: pick(["Well-exposed — good lighting balance", "Lighting looks great here", "Nicely exposed shot"], for: score), weight: score.exposureScore * 0.7))
            } else if score.compositionScore > 0.72 {
                sigs.append(RUSignal(text: pick(["Solid composition", "Good framing and balance", "Well-composed shot"], for: score), weight: score.compositionScore * 0.7))
            }

            if sigs.isEmpty { sigs.append(RUSignal(text: "Solid overall photo", weight: 0.5)) }

            let sorted = sigs.sorted { $0.weight > $1.weight }
            return sorted.prefix(4).map(\.text).joined(separator: " · ")
        }

        if isDatingMode {
            return buildDatingReasoning(score, datingVibe: datingVibe, datingAudience: datingAudience)
        }

        if isPromptMode && isOutfitPrompt(promptText) {
            return buildOutfitReasoning(score, promptText: promptText)
        }

        let wantsAwkward    = intent?.wantsAwkward    ?? false
        let wantsSerious    = intent?.wantsSerious    ?? false
        let wantsImperfect  = intent?.wantsImperfect  ?? false
        let wantsDark       = intent?.wantsDark       ?? false
        let wantsHighKey    = intent?.wantsHighKey    ?? false
        let wantsEyesClosed = intent?.wantsEyesClosed ?? false

        // ── Compute contribution magnitude per dimension ──────────────────
        // Each entry: (text, contribution). Sorted descending so highest-impact reasons lead.
        struct ScoredReason { let text: String; let contribution: Float }
        var scored: [ScoredReason] = []

        func add(_ text: String, contribution: Float) {
            scored.append(ScoredReason(text: text, contribution: contribution))
        }

        // ── Prompt / reference match — these are the primary signal in prompt mode ──
        if isPromptMode, let ps = score.promptScore {
            let rcPW = RemoteConfigService.shared.promptWeight
            let contrib = ps * rcPW
            let label = contentTypeLabel(from: promptText)
            if ps > 0.28      { add("Strong match — \(label)", contribution: contrib) }
            else if ps > 0.22 { add("Good match — \(label)", contribution: contrib * 0.85) }
            else              { add("Best available match", contribution: contrib * 0.6) }
        }

        if let rs = score.referenceScore, rs > 0.45 {
            // Boost contribution weight when the user is in reference-driven mode
            let contrib = rs * (isReferenceDriven ? 0.50 : 0.35)

            // Purpose-specific high / mid pools
            let highPool: [String]
            let midPool: [String]

            switch purposeTag {
            case BatchPurpose.social.rawValue:
                highPool = ["Matches your Instagram aesthetic — on-brand for your feed",
                             "Very close to the look in your reference photos — fits your feed",
                             "Matches the lighting and vibe of your reference photos",
                             "Strong style match — this feels like the rest of your content"]
                midPool  = ["Fits the aesthetic and vibe of your reference photos",
                             "Aligns with your reference photo style",
                             "Style is consistent with your reference photos"]
            case BatchPurpose.professional.rawValue:
                highPool = ["Matches your professional reference look",
                             "Consistent with the style of your reference headshots",
                             "Strong match to your professional reference photos"]
                midPool  = ["Aligns with your headshot style",
                             "Style aligns with your reference photos",
                             "Consistent look with your professional references"]
            case BatchPurpose.dating.rawValue:
                highPool = ["Fits your dating profile style — consistent look across your photos",
                             "Strong match to your reference photo style",
                             "Looks consistent with your reference photos — cohesive profile"]
                midPool  = ["Aligns with your reference photo style",
                             "Style matches your reference photos reasonably well",
                             "Reference photos influenced this pick — style aligns"]
            default:
                if isReferenceDriven {
                    highPool = ["Closely matches your reference photos — chosen for you",
                                 "Very strong reference match — this is your style",
                                 "Reference photos clearly influenced this — strong visual alignment"]
                    midPool  = ["Aligns well with your reference style",
                                 "Good reference match — style is consistent",
                                 "Reference photos point to this one — solid alignment"]
                } else {
                    highPool = ["Very close to your reference photos — strong style match",
                                 "Strong match to the look in your reference photos",
                                 "Reference photos clearly influenced this pick — high similarity"]
                    midPool  = ["Aligns well with your reference style",
                                 "Style is consistent with your reference photos",
                                 "Good match to your reference photo aesthetic"]
                }
            }

            if rs > 0.68      { add(pick(highPool, for: score), contribution: contrib) }
            else if rs > 0.52 { add(pick(midPool,  for: score), contribution: contrib * 0.85) }
            // Below 0.52: reference score is weak — don't mention it, avoids false attribution
        }

        // ── Category-specific contributions (non-prompt mode) ─────────────
        if !isPromptMode {
            // Category weights — must match the actual formula in weightedScore exactly.
            // Previously these diverged (e.g. mugshot used 0.45 here but 0.41 in the formula),
            // causing the reasoning text to lie about which dimensions drove the score.
            let catWeight: Float
            let aesWeight: Float
            let qualWeight: Float
            let compWeight: Float
            switch category {
            case .mugshot:   catWeight = 0.18; aesWeight = 0.14; qualWeight = 0.41; compWeight = 0.20
            case .nature:    catWeight = 0.58; aesWeight = 0.18; qualWeight = 0.12; compWeight = 0.00
            case .vacation:  catWeight = 0.36; aesWeight = 0.27; qualWeight = 0.27; compWeight = 0.00
            case .concert:   catWeight = 0.40; aesWeight = 0.30; qualWeight = 0.18; compWeight = 0.00
            case .edgy:      catWeight = 0.27; aesWeight = 0.49; qualWeight = 0.12; compWeight = 0.00
            }

            let qualContrib = score.qualityScore * qualWeight
            let catContrib  = score.categoryScore * catWeight
            let aesContrib  = score.aestheticScore * aesWeight
            let compContrib = score.compositionScore * compWeight

            // Quality / sharpness — always its own bullet so the exposure signal
            // can be a separate entry. Previously combined with " · " which caused
            // the display layer to split it into two bullets mid-string.
            if qualContrib > 0.15 || score.qualityScore > 0.65 {
                let sharpLabel: String
                switch score.qualityScore {
                case 0.93...:
                    sharpLabel = pick(["Tack-sharp — outstanding focus",
                                       "Crystal-clear — every detail registers",
                                       "Razor-sharp — technically flawless"], for: score)
                case 0.85..<0.93:
                    sharpLabel = pick(["Exceptionally sharp",
                                       "Excellent clarity and sharpness",
                                       "Very sharp — great technical execution"], for: score)
                case 0.75..<0.85:
                    sharpLabel = pick(["Sharp and crisp",
                                       "Well-focused and clear",
                                       "Solid sharpness — subject is crisp"], for: score)
                case 0.65..<0.75:
                    sharpLabel = pick(["Well-focused",
                                       "Focus is good on the subject",
                                       "Decently sharp overall"], for: score)
                default:
                    sharpLabel = pick(["Acceptable sharpness",
                                       "Focus is passable",
                                       "Reasonably clear"], for: score)
                }
                add(sharpLabel, contribution: qualContrib)

                // Exposure as a separate entry so it has its own capitalised bullet
                switch score.exposureScore {
                case 0.97...:
                    add(pick(["Perfectly exposed",
                               "Flawless exposure — nothing blown or crushed",
                               "Ideal exposure — highlights and shadows balanced"], for: score),
                        contribution: qualContrib * 0.55)
                case 0.88..<0.97:
                    add(pick(["Clean, balanced exposure",
                               "Great exposure — well lit throughout",
                               "Well-exposed — light is handled beautifully"], for: score),
                        contribution: qualContrib * 0.40)
                case 0.72..<0.88:
                    add(pick(["Good exposure",
                               "Decent lighting — well enough lit",
                               "Exposure is solid"], for: score),
                        contribution: qualContrib * 0.28)
                default: break
                }
            }

            // Category signal
            if catContrib > 0.15 {
                switch category {
                case .mugshot:
                    switch score.categoryScore {
                    case 0.88...:
                        add(pick(["Exceptional portrait — classic headshot framing",
                                   "Standout portrait — strong headshot quality",
                                   "Excellent portrait framing — professional feel"], for: score),
                            contribution: catContrib)
                    case 0.72..<0.88:
                        add(pick(["Strong portrait composition",
                                   "Solid headshot framing — subject reads clearly",
                                   "Well-composed portrait"], for: score),
                            contribution: catContrib * 0.9)
                    case 0.55..<0.72:
                        add(pick(["Solid portrait framing",
                                   "Decent headshot composition",
                                   "Portrait framing is clean"], for: score),
                            contribution: catContrib * 0.75)
                    default: break
                    }
                case .nature:
                    if !score.hasFace && !score.hasAnimal {
                        add(pick(["Clean nature scene — no people in frame",
                                   "Pure natural scene — no distractions",
                                   "Uncluttered natural environment"], for: score),
                            contribution: catContrib + 0.05)
                    }
                    switch score.categoryScore {
                    case 0.88...:
                        add(pick(["Standout natural scene",
                                   "Exceptional nature composition",
                                   "The environment really comes alive here"], for: score),
                            contribution: catContrib)
                    case 0.72..<0.88:
                        add(pick(["High scene relevance",
                                   "Strong natural environment content",
                                   "The natural setting reads well"], for: score),
                            contribution: catContrib * 0.9)
                    case 0.55..<0.72:
                        add(pick(["Good natural environment content",
                                   "Solid nature shot",
                                   "Natural scene comes through clearly"], for: score),
                            contribution: catContrib * 0.75)
                    default: break
                    }
                case .vacation:
                    switch score.categoryScore {
                    case 0.88...:
                        add(pick(["Excellent travel shot — strong sense of place",
                                   "Standout travel moment — location really shines",
                                   "Great destination shot — scene tells the story",
                                   "Travel photo with real personality — you and the place both shine"], for: score),
                            contribution: catContrib)
                    case 0.72..<0.88:
                        add(pick(["Great location shot",
                                   "Strong sense of place — location comes through",
                                   "Good travel framing — setting reads clearly"], for: score),
                            contribution: catContrib * 0.9)
                    case 0.55..<0.72:
                        add(pick(["Good travel composition",
                                   "Solid vacation shot — place is recognisable",
                                   "Travel context is clear in the frame"], for: score),
                            contribution: catContrib * 0.75)
                    default: break
                    }
                case .concert:
                    switch score.categoryScore {
                    case 0.88...:
                        add(pick(["Captures the peak energy of the moment",
                                   "Electric atmosphere — you can feel the energy",
                                   "Nails the live music vibe — high energy frame"], for: score),
                            contribution: catContrib)
                    case 0.72..<0.88:
                        add(pick(["Strong event atmosphere",
                                   "Good live event energy — scene comes through",
                                   "Event mood is captured well"], for: score),
                            contribution: catContrib * 0.9)
                    case 0.55..<0.72:
                        add(pick(["Good live event content",
                                   "Event context is clear",
                                   "Solid concert shot"], for: score),
                            contribution: catContrib * 0.75)
                    default: break
                    }
                case .edgy:
                    switch score.aestheticScore {
                    case 0.85...:
                        add(pick(["Striking dark, cinematic aesthetic",
                                   "Moody and dramatic — exactly the right tone",
                                   "Bold, cinematic edge — stands out immediately"], for: score),
                            contribution: aesContrib)
                    case 0.70..<0.85:
                        add(pick(["Strong moody, dramatic tone",
                                   "Dark aesthetic comes through clearly",
                                   "Good cinematic mood — edgy and intentional"], for: score),
                            contribution: aesContrib * 0.9)
                    case 0.55..<0.70:
                        add(pick(["Good edgy composition",
                                   "Decent dark aesthetic — could push it further",
                                   "Edgy tone is present — has the right feel"], for: score),
                            contribution: aesContrib * 0.75)
                    default: break
                    }
                }
            }

            // Aesthetic signal (skip for edgy — handled above)
            // Use natural-language labels so "&" doesn't appear mid-sentence.
            if category != .edgy && aesContrib > 0.10 {
                let label: String
                switch aesthetics.first {
                case .brightAiry:    label = "bright and airy"
                case .darkMoody:     label = "dark and moody"
                case .warmGolden:    label = "warm and golden"
                case .cleanMinimal:  label = "clean and minimal"
                case .boldDramatic:  label = "bold and dramatic"
                case .candidRaw:     label = "candid and natural"
                default:             label = "selected"
                }
                switch score.aestheticScore {
                case 0.90...:
                    add(pick(["Excellent \(label) aesthetic",
                               "Really captures the \(label) feel",
                               "Standout \(label) look — nails the vibe",
                               "Strong \(label) energy — exactly the right tone"], for: score),
                        contribution: aesContrib)
                case 0.78..<0.90:
                    add(pick(["Strong \(label) look",
                               "Good \(label) aesthetic — feel comes through",
                               "Solid \(label) vibe — works well for this style"], for: score),
                        contribution: aesContrib * 0.9)
                case 0.62..<0.78:
                    add(pick(["Good \(label) style",
                               "Decent \(label) aesthetic — room to refine",
                               "\(label.capitalized) feel is present — could lean in further"], for: score),
                        contribution: aesContrib * 0.75)
                default: break
                }
            }

            // Composition (meaningful for mugshot)
            if compContrib > 0.12 && score.hasFace {
                switch score.compositionScore {
                case 0.90...:      add("Excellent composition — subject on rule-of-thirds", contribution: compContrib)
                case 0.75..<0.90:  add("Well-composed — subject positioned naturally", contribution: compContrib * 0.9)
                default: break
                }
            }
        } else {
            // Prompt mode: quality is still meaningful as the secondary signal
            if score.qualityScore > 0.65 {
                let sharpLabel: String
                switch score.qualityScore {
                case 0.93...:      sharpLabel = "Tack-sharp — outstanding focus"
                case 0.85..<0.93:  sharpLabel = "Exceptionally sharp"
                case 0.75..<0.85:  sharpLabel = "Sharp and crisp"
                default:           sharpLabel = "Well-focused"
                }
                add(sharpLabel, contribution: score.qualityScore * (1.0 - RemoteConfigService.shared.promptWeight))
            }
        }

        // ── Multiplier bonuses (face-related — appended after primary signals) ──
        // Bokeh
        if score.hasFace {
            let separation = score.qualityScore - score.backgroundSharpness
            if separation > 0.35 {
                add(pick(["Nice background blur separates subject (bokeh)",
                           "Clean subject separation — bokeh effect works well",
                           "Background falls away naturally — subject pops",
                           "Sharp subject, soft background — great depth of field"], for: score),
                    contribution: 0.18)
            } else if separation > 0.15 {
                add(pick(["Soft background keeps focus on subject",
                           "Background softens naturally — eye goes straight to you",
                           "Subtle depth of field — subject stands out cleanly"], for: score),
                    contribution: 0.10)
            }
        } else {
            switch score.backgroundSharpness {
            case 0.70...:
                add(pick(["High depth of field — scene is sharp throughout",
                           "Everything in focus — great for showing the full scene",
                           "Wide depth of field — scene rendered crisply"], for: score),
                    contribution: 0.08)
            case ..<0.25:
                add(pick(["Shallow depth of field — selective focus",
                           "Beautiful selective focus — subject isolated cleanly",
                           "Subject isolated with shallow focus — intentional and clean"], for: score),
                    contribution: 0.07)
            default: break
            }
        }

        // Expression / smile
        if score.hasFace {
            if wantsSerious {
                if !score.isSmiling {
                    add(pick(["Serious, focused expression",
                               "Neutral expression — composed and intentional",
                               "No smile — grounded and self-assured look"], for: score),
                        contribution: 0.14)
                }
            } else if wantsAwkward {
                add(score.poseScore > 0.45
                    ? pick(["Fun, spontaneous pose", "Playful energy — candid moment works", "Lively and natural — authentically unposed"], for: score)
                    : pick(["Candid, unposed moment", "Genuine unscripted moment — real and relatable", "Raw and authentic — nothing staged about this"], for: score),
                    contribution: 0.10)
            } else if score.isSmiling {
                let smileContrib = 0.08 + score.genuineSmileScore * 0.12
                switch score.genuineSmileScore {
                case 0.80...:
                    add(pick(["You look genuinely happy — bright, real smile",
                               "Authentic smile — the warmth reads clearly",
                               "Big genuine smile — instantly likable",
                               "Real, radiant smile — hard to fake that"], for: score),
                        contribution: smileContrib)
                case 0.55...:
                    add(pick(["Nice natural smile — warm and approachable",
                               "Natural, relaxed smile — friendly energy",
                               "Warm smile — approachable and genuine"], for: score),
                        contribution: smileContrib)
                default:
                    add(pick(["Subtle smile — friendly and relaxed",
                               "Soft smile — calm and inviting",
                               "Gentle smile — comfortable and natural"], for: score),
                        contribution: smileContrib)
                }
            }
        }

        // Eye state — only claim when analyser returned a definite, confident verdict.
        // .unknown (sunglasses, squint, extreme profile) stays silent.
        if score.hasFace {
            if wantsEyesClosed {
                if score.eyeState == .closed, score.eyeOpenConfidence < 0.30 {
                    add(pick(["Eyes softly closed — dreamy look achieved",
                               "Eyes closed — soft and ethereal",
                               "Closed eyes give it a dreamy, intentional feel"], for: score),
                        contribution: 0.10)
                }
            } else {
                switch score.eyeState {
                case .open where score.eyeOpenConfidence >= 0.75:
                    add(pick(["Your eyes look open and expressive",
                               "Eyes look clear and open",
                               "Open, alert eyes — present and engaged",
                               "Eyes look open — sharp and attentive"], for: score),
                        contribution: 0.12)
                case .closed where score.eyeOpenConfidence < 0.30:
                    if closedEyePenaltyRelief(for: score, tolerance: closedEyeTolerance) > 0.35 {
                        add(pick(["Closed eyes feel intentional with the expression",
                                   "Closed-eye moment works with the pose and angle",
                                   "Expression and framing make the closed-eye look work"], for: score),
                            contribution: 0.20)
                    } else {
                        add(pick(["Eyes appear closed",
                                   "Looks like eyes are closed in this one",
                                   "Eyes appear closed — worth checking"], for: score),
                            contribution: 0.05)
                    }
                case .unknown:
                    add(pick(["Eye state uncertain — face angle or lighting limits confidence",
                               "Eye visibility is uncertain — worth checking manually",
                               "Eyes are hard to read here — use your judgment"], for: score),
                        contribution: 0.035)
                default:
                    break
                }
            }
        }

        // Gaze direction
        if score.hasFace {
            switch score.faceYaw {
            case ..<0.10:
                if score.eyeState == .open && score.eyeOpenConfidence >= 0.65 {
                    add(pick(["Looking directly at camera — engaging eye contact",
                               "Direct eye contact — confident and engaging",
                               "Eyes straight to camera — strong, present look",
                               "Full eye contact — pulls the viewer in immediately"], for: score),
                        contribution: 0.09)
                } else {
                    add(pick(["Face angled toward camera — strong presence",
                               "Facing camera — clean, direct framing",
                               "Head angle is direct and composed"], for: score),
                        contribution: 0.06)
                }
            case 0.40...:
                add(pick(["Strong profile angle",
                           "Classic profile — dramatic and sculptural",
                           "Side profile — cinematic and bold"], for: score),
                    contribution: 0.06)
            case 0.25..<0.40:
                add(pick(["Natural three-quarter angle",
                           "Slight off-camera glance — candid and relaxed",
                           "Three-quarter view — flattering and natural"], for: score),
                    contribution: 0.05)
            default: break
            }
        }

        // Pose quality
        if score.hasFace && !wantsAwkward {
            switch score.poseScore {
            case 0.80...:
                add(pick(["You look relaxed and confident",
                           "Relaxed, natural posture — great body language",
                           "Comfortable and confident stance — nothing forced",
                           "Open, natural body language — looks effortless"], for: score),
                    contribution: 0.11)
            case 0.60..<0.80:
                add(pick(["Natural, comfortable stance",
                           "Easy, relaxed posture",
                           "Comfortable body language — nothing stiff"], for: score),
                    contribution: 0.07)
            default: break
            }
        }

        // Face count context — with user face identification context when available
        if score.hasFace {
            switch score.faceCount {
            case 1:
                add(pick(["Solo shot — you're the clear subject",
                           "Just you in frame — clean and focused",
                           "Solo — no distractions, all eyes on you"], for: score),
                    contribution: 0.06)
            case 2:
                if score.userFaceIdentified {
                    let pool = identityReasonPool(
                        high: ["Group shot — focused on you",
                               "Two people, but the focus is on you",
                               "Identified your face — scoring reflects how you look here"],
                        mid: ["Likely found you in the two-person shot",
                              "Two people in frame — likely scoring the matched face",
                              "Likely matched your face from references"],
                        low: ["Possible face match — double-check this two-person shot",
                              "Two people in frame — identity match is lower confidence",
                              "Face match is tentative, so review this one manually"],
                        confidence: score.userFaceMatchConfidence
                    )
                    add(pick(pool, for: score),
                        contribution: 0.04)
                } else {
                    add(pick(["Two people in frame",
                               "You and one other person — decent framing",
                               "Two faces — both visible and clear"], for: score),
                        contribution: 0.04)
                }
            case 3...:
                if score.userFaceIdentified {
                    let pool = identityReasonPool(
                        high: ["Found you in the group — your face is the focus",
                               "Group shot — your expression and look drive the score",
                               "Identified you among \(score.faceCount) people — scoring based on how you look"],
                        mid: ["Likely found you in the group — your face drives the score",
                              "Group shot — likely matched your face from references",
                              "Likely identified you among \(score.faceCount) people"],
                        low: ["Possible match in the group — review manually",
                              "Group identity match is tentative here",
                              "Found a possible match among \(score.faceCount) people"],
                        confidence: score.userFaceMatchConfidence
                    )
                    add(pick(pool, for: score),
                        contribution: 0.04)
                } else {
                    add(pick(["\(score.faceCount) people in frame",
                               "Group of \(score.faceCount) — busy frame but you stand out",
                               "\(score.faceCount) faces visible — group shot"], for: score),
                        contribution: 0.03)
                }
            default: break
            }
        }

        // Animal
        if score.hasAnimal {
            switch score.animalEyeConfidence {
            case 0.65...:      add("Animal facing camera with eyes open", contribution: 0.09)
            case 0.35..<0.65:  add("Animal well-positioned in frame", contribution: 0.06)
            default:           add("Animal present in frame", contribution: 0.04)
            }
        }

        // Intent-specific framing (low contribution — contextual)
        if wantsImperfect {
            add(score.negativeScore > 0.25 ? "Authentic imperfect aesthetic — grain and character"
                                           : "Natural film-like quality", contribution: 0.07)
        } else if wantsDark && score.exposureScore < 0.50 {
            add("Dark, low-light atmosphere as intended", contribution: 0.08)
        } else if wantsHighKey && score.exposureScore > 0.60 {
            // Bright / high-key photos should have *high* exposure scores,
            // not low ones — the previous check was inverted.
            add("Bright, high-key exposure as intended", contribution: 0.08)
        } else if score.negativeScore < 0.05 {
            add("No technical flaws detected", contribution: 0.05)
        }

        // Color harmony — surface when it's a differentiating factor
        if score.colorHarmonyScore > 0.75 && !score.hasFace {
            add("Cohesive, harmonious color palette", contribution: score.colorHarmonyScore * 0.08)
        }

        // ── Sort by contribution descending, deduplicate, cap at 4 ──────────
        scored.sort { $0.contribution > $1.contribution }

        // Deduplicate by checking for prefix similarity (avoids near-duplicate phrases)
        var seen: [String] = []
        var deduped: [String] = []
        for r in scored {
            let key = String(r.text.prefix(20))
            if !seen.contains(key) {
                seen.append(key)
                deduped.append(r.text)
            }
            if deduped.count >= 4 { break }
        }

        if deduped.isEmpty {
            deduped.append("Best overall balance of quality and style")
        }

        return deduped.joined(separator: " · ")
    }

    private func identityReasonPool(high: [String], mid: [String], low: [String], confidence: Float?) -> [String] {
        guard let confidence else { return mid }
        if confidence >= 0.74 { return high }
        if confidence >= 0.56 { return mid }
        return low
    }

    // MARK: - Dating-specific reasoning

    private func buildDatingReasoning(_ score: PhotoScore, datingVibe: String, datingAudience: String) -> String {
        var reasons: [String] = []

        // ── Vibe match ────────────────────────────────────────────────────
        if let ps = score.promptScore {
            let vibeLower = datingVibe.lowercased()
            // Candid / natural vibes get a personality note because authenticity is the top
            // predictor of swipe-right behaviour on dating apps.
            let isPersonalityVibe = vibeLower.contains("candid") || vibeLower.contains("natural")
                                 || vibeLower.contains("fun") || vibeLower.contains("playful")
                                 || vibeLower.contains("adventurous")
            switch ps {
            case 0.30...:
                let note = isPersonalityVibe ? " — genuine personality comes through clearly"
                                             : " — exactly the energy you're going for"
                reasons.append("Strong \(datingVibe.lowercased()) vibe\(note)")
            case 0.24...:
                reasons.append("Good \(datingVibe.lowercased()) vibe — fits the look well")
            case 0.18...:
                reasons.append("Some \(datingVibe.lowercased()) energy — best available for this style")
            default:
                reasons.append("Best overall photo for your dating profile")
            }
        } else {
            reasons.append("Best overall photo for your dating profile")
        }

        // ── Audience note ─────────────────────────────────────────────────
        let audienceLower = datingAudience.lowercased()
        switch audienceLower {
        case "women":
            reasons.append("Top pick for attracting women — genuine expression and warm energy score highest")
        case "men":
            reasons.append("Top pick for attracting men — confidence and authenticity shine here")
        case "everyone":
            break   // broad audience → no specific note needed, keeps copy tight
        default:
            if !audienceLower.isEmpty {
                reasons.append("Optimized for \(datingAudience) — personality comes through clearly")
            }
        }

        // ── Solo vs group ─────────────────────────────────────────────────
        if score.hasFace {
            switch score.faceCount {
            case 1:  reasons.append("Solo shot — makes it clear it's you")
            case 2:  reasons.append("Two people in frame — make sure your audience knows which one is you")
            default: reasons.append("Group shot — consider cropping or using a solo photo for your main profile picture")
            }
        } else {
            reasons.append("No face detected — works well as a secondary photo showing your lifestyle")
        }

        // ── Eye contact ───────────────────────────────────────────────────
        // Only claim eye contact when the eye analyser actually verified the eyes are open.
        // Profile yaw is a necessary but not sufficient condition; `.unknown` (sunglasses,
        // squint, asymmetric) must stay silent to avoid misleading dating-profile advice.
        if score.hasFace {
            let lookingAway = score.faceYaw > 0.20
            if !lookingAway, score.eyeState == .open {
                switch score.eyeOpenConfidence {
                case 0.80...: reasons.append("Direct eye contact — creates instant connection and confidence")
                case 0.55...: reasons.append("Good eye contact — approachable and engaging")
                default:      break
                }
            } else if !lookingAway, score.eyeState == .unknown {
                reasons.append("Face is angled toward camera, but eye visibility is uncertain — review before posting")
            } else if lookingAway {
                switch score.faceYaw {
                case 0.40...: reasons.append("Looking away creates a candid, natural feel")
                default:      reasons.append("Slight off-camera look — feels natural and unstaged")
                }
            }
        }

        // ── Expression ────────────────────────────────────────────────────
        if score.hasFace {
            switch score.genuineSmileScore {
            case 0.75...:
                reasons.append("You look genuinely happy — a real smile is one of the biggest swipe-right signals")
            case 0.50..<0.75:
                reasons.append("Nice natural smile — warm and approachable")
            case 0.25..<0.50:
                reasons.append("Relaxed, natural expression — authentic and confident")
            default:
                reasons.append("Relaxed expression — looks grounded and self-assured")
            }
        }

        // ── Body / pose ───────────────────────────────────────────────────
        if score.hasFace {
            // subjectHeight: 0 = headshot only, 0.5+ = torso visible, 0.8+ = full body
            switch score.subjectHeight {
            case 0.80...:
                reasons.append("Full body shown — great for showing off your figure and giving a sense of your height")
            case 0.50..<0.80:
                reasons.append("Good framing — torso visible, shows your overall look")
            default: break
            }

            switch score.poseScore {
            case 0.80...: reasons.append("You look relaxed and confident — natural body language reads really well")
            case 0.55..<0.80: reasons.append("Comfortable, open stance")
            case ..<0.35: reasons.append("Body angle is a little awkward — a more open stance would strengthen this")
            default: break
            }
        }

        // ── Technical quality ─────────────────────────────────────────────
        switch score.qualityScore {
        case 0.85...: reasons.append("Crisp and sharp — looks great at thumbnail size on dating apps")
        case 0.65...: reasons.append("Good photo quality — clear and focused")
        default:      break
        }

        switch score.exposureScore {
        case 0.88...: reasons.append("Great lighting — bright and flattering on your face")
        case 0.72..<0.88: reasons.append("Good lighting")
        default: break
        }

        // ── Bokeh / background ────────────────────────────────────────────
        if score.hasFace {
            let separation = score.qualityScore - score.backgroundSharpness
            if separation > 0.30 {
                reasons.append("Blurred background draws all attention to you — a polished, professional look")
            }
        }

        if reasons.isEmpty {
            reasons.append("Best overall balance for a dating profile photo")
        }

        return reasons.joined(separator: " · ")
    }

    // MARK: - Outfit-specific reasoning

    /// Returns true when the prompt text indicates this is an outfit check batch.
    private func isOutfitPrompt(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["outfit", "well-dressed", "stylish", "color harmony", "complementary colors",
                "occasion", "fashion", "confident person standing", "appropriate outfit"]
            .contains { lower.contains($0) }
    }

    private func buildOutfitReasoning(_ score: PhotoScore, promptText: String) -> String {
        var reasons: [String] = []

        // Prompt match — how well the outfit hits the occasion/focus
        if let ps = score.promptScore {
            if ps > 0.28      { reasons.append("Strong outfit match for the occasion") }
            else if ps > 0.22 { reasons.append("Good outfit choice for this setting") }
            else              { reasons.append("Best available outfit shot from the batch") }
        }

        // Color harmony — the most important signal for outfit evaluation
        switch score.colorHarmonyScore {
        case 0.85...:     reasons.append("Excellent color harmony — outfit palette is cohesive and flattering")
        case 0.70..<0.85: reasons.append("Good color coordination — tones work well together")
        case 0.55..<0.70: reasons.append("Decent color balance — room to refine")
        default:          reasons.append("Mixed color palette — try combining fewer hues for a cleaner look")
        }

        // Outfit contrast against background — does the outfit pop or blend in?
        let contrast = outfitContrastScore(image: score.image)
        switch contrast {
        case 0.65...:      reasons.append("Your outfit really pops against the background — great color contrast")
        case 0.40..<0.65:  reasons.append("Your outfit contrasts well with the background")
        case 0.20..<0.40:  reasons.append("Outfit blends somewhat into the background — a contrasting color would make it stand out more")
        default:           reasons.append("Outfit color nearly matches the background — try a bolder color for more impact")
        }

        // Confidence / pose — body language shows how well you wear the outfit
        if score.hasFace {
            switch score.poseScore {
            case 0.80...:      reasons.append("Confident, upright posture — the outfit reads well")
            case 0.60..<0.80:  reasons.append("Relaxed stance — outfit looks natural on you")
            case ..<0.40:      reasons.append("Body angle is slightly off — a more open stance would show the outfit better")
            default: break
            }

            // Genuine smile signals comfort in the outfit
            if score.genuineSmileScore > 0.6 {
                reasons.append("Genuine smile — you look comfortable and confident in this outfit")
            }
        }

        // Sharpness — clear detail shot matters for evaluating fabric/fit
        if score.qualityScore > 0.75 {
            reasons.append("Sharp, detailed shot — outfit textures and fit are clearly visible")
        } else if score.qualityScore < 0.45 {
            reasons.append("Photo is slightly soft — hard to judge the outfit's finer details")
        }

        // Exposure — proper lighting is key to seeing colors accurately
        switch score.exposureScore {
        case 0.88...:      reasons.append("Well-lit — colors appear true to life")
        case 0.55..<0.88:  break
        default:           reasons.append("Lighting makes it harder to judge the outfit's true colors")
        }

        if reasons.isEmpty { reasons.append("Best outfit photo from this batch") }
        return reasons.joined(separator: " · ")
    }

    // MARK: - Content type label for reasoning

    /// Extracts a human-readable content label from a free-form prompt for use in reasoning strings.
    private func contentTypeLabel(from prompt: String) -> String {
        let lower = prompt.lowercased()
        let checks: [(keywords: [String], label: String)] = [
            (["outfit", "well-dressed", "fashion", "clothing", "style", "color harmony", "occasion"], "outfit photography"),
            (["food", "dish", "meal", "eat", "restaurant", "cuisine", "recipe", "drink", "coffee", "snack"], "food photography"),
            (["animal", "pet", "dog", "cat", "bird", "wildlife", "horse", "kitten", "puppy"], "animal photography"),
            (["sunset", "sunrise", "landscape", "scenery", "mountain", "forest", "nature", "sky", "ocean", "lake", "waterfall"], "landscape photography"),
            (["city", "urban", "street", "architecture", "building", "skyline"], "urban photography"),
            (["portrait", "headshot", "selfie", "face", "person", "people"], "portrait photography"),
            (["wedding", "ceremony", "bride", "groom"], "wedding photography"),
            (["sport", "action", "fitness", "gym", "running", "jumping"], "action photography"),
            (["product", "item", "object", "detail", "macro", "still life"], "product photography"),
            (["night", "dark", "moody", "noir", "low light"], "low-light photography"),
            (["abstract", "pattern", "texture", "color", "artistic"], "artistic photography"),
        ]
        for check in checks {
            if check.keywords.contains(where: { lower.contains($0) }) {
                return check.label
            }
        }
        return "your prompt"
    }
}
