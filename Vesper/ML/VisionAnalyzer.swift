//
//  VisionAnalyzer.swift
//  Vesper
//
//  Created by Dennis Mach on 4/2/26.
//

import Vision
import UIKit
import CoreImage

/// Verdict of the eye-open analyser. Three states — importantly including `.unknown` —
/// let downstream code (reasoning, scoring, delete-candidate logic) distinguish
/// "I'm confident the eyes are open/closed" from "I can't tell." Before this type existed,
/// an ambiguous reading defaulted to a 0.5 confidence that downstream code treated as
/// "slightly open," which produced false "Eyes open" claims on sunglasses, squints, and
/// extreme profile angles.
enum EyeState: String, Equatable {
    case open
    case closed
    case unknown
}

/// Per-face data for all significant faces in a photo (>= 20% of dominant face area).
/// BatchProcessor uses this to identify which face belongs to the user when reference
/// face embeddings are available, then overrides the photo's quality scores accordingly.
struct CandidateFaceData {
    let boundingBox: CGRect       // Vision normalised (y-up)
    let eyeState: EyeState
    let eyeOpenConfidence: Float
    let eyeSymmetryScore: Float   // 1 = balanced/reliable, 0 = strongly uneven
    let eyeOcclusionScore: Float  // 1 = eyes likely hidden by glasses, shadows, hair, or missing landmarks
    let genuineSmileScore: Float
    let faceYaw: Float
    let detectionConfidence: Float
    let area: Float               // boundingBox.width × height — for sorting and dominance checks
}

struct PhotoScore {
    let image: UIImage
    var originalIndex: Int = 0          // position in the original input array — preserved through sorts
    var qualityScore: Float
    var hasFace: Bool = false
    var faceCount: Int = 0
    var isSmiling: Bool = false
    var genuineSmileScore: Float = 0.5   // 0.0 = no smile, 0.5 = lips-only, 1.0 = Duchenne (lip + eye crinkle)
    var eyeState: EyeState = .unknown    // canonical eye verdict — reasoning / scoring should check this first
    var eyesOpen: Bool = true            // legacy mirror of eyeState == .open; kept for existing call sites
    var eyeOpenConfidence: Float = 0.5   // 0 = definitely closed, 1 = definitely open; 0.5 = neutral/unknown
    var eyeSymmetryScore: Float = 0.75    // 1 = balanced eyes; low = uneven squint/wink/landmark mismatch
    var eyeOcclusionScore: Float = 0.0    // high when eyes are hidden/ambiguous rather than actually closed
    var faceYaw: Float = 0               // radians; ~0 = looking at camera, larger = away
    var faceBoundingBox: CGRect? = nil   // normalised Vision coordinates — used for subject-area sharpness
    var hasAnimal: Bool = false          // true when VNDetectAnimalBodyPoseRequest detects a dog/cat
    var animalEyeConfidence: Float = 0.5 // proxy: avg joint detection confidence — high = animal facing camera
    var poseScore: Float = 0.5           // 1.0 = natural, upright pose; lower = awkward tilt, turned away, or occluded
    var isSimilar: Bool = false          // tagged by near-duplicate detection (cosine sim >= 0.85)
    var exposureScore: Float = 0.5       // 1.0 = well exposed, lower = blown highlights or crushed blacks
    var backgroundSharpness: Float = 0.5 // sharpness of non-subject area — low bg + sharp face = bokeh
    var compositionScore: Float = 0.5    // face/subject near rule-of-thirds power points
    var colorHarmonyScore: Float = 0.5   // hue-coherence of the image palette (0 = chaotic, 1 = ideal harmony)
    var categoryScore: Float = 0.5
    var aestheticScore: Float = 0.5
    var referenceScore: Float? = nil
    var promptScore: Float? = nil
    var feedbackScore: Float? = nil
    var clipEmbedding: [Float]? = nil   // cached for near-duplicate suppression
    var negativeScore: Float = 0.0      // max cosine similarity to "bad photo" descriptions — acts as penalty
    var batchRelativeScore: Float = 0.5 // within similar shots: 1 = strongest frame, 0 = weaker alternate
    var batchComparisonNote: String = ""

    /// Estimated normalised subject height (0 = no body / partial torso, 1 = full-body, head-to-toe).
    /// Derived from VNDetectHumanBodyPoseRequest keypoints (head→ankle vertical span).
    /// Defaults to 0.5 (neutral) when no pose was detected.
    /// Only contributes to scoring when the prompt requests "tall" / "full body" / etc.
    var subjectHeight: Float = 0.5
    /// Composite "vibe" score — gentle bg blur + warm tones + harmonious palette.
    /// Captures the modern aesthetic where slightly-soft, well-toned shots beat
    /// clinical-sharp ones. Always contributes a small weight in scoring.
    var vibeScore: Float = 0.5
    /// CLIP cosine similarity to a centroid of trendy aesthetic phrases
    /// ("film grain", "candid", "golden hour", "y2k", "mirror selfie", ...).
    /// Lazily populated in BatchProcessor when CLIP is available.
    var trendScore: Float = 0.5
    /// All significant faces in this photo (>= 20% of dominant face area), sorted largest first.
    /// BatchProcessor matches these against reference face embeddings to find the user's face,
    /// then overrides eyeState/smile/faceYaw with the identified face's values.
    var candidateFaces: [CandidateFaceData] = []
    /// Set to true by BatchProcessor once user face identification has succeeded and the
    /// quality signals (eyeState, smile, etc.) have been overridden with the user's face data.
    var userFaceIdentified: Bool = false
    /// Confidence that `userFaceIdentified` refers to the actual user, derived from CLIP
    /// face-crop similarity and the margin over the next-best candidate. 0 = unknown/not matched.
    var userFaceMatchConfidence: Float = 0

    var finalScore: Float {
        (qualityScore * 0.4) + (categoryScore * 0.3) + (aestheticScore * 0.3)
    }
}

class VisionAnalyzer {
    // Shared process-wide CIContext keeps Metal resources pooled across
    // the concurrent scoring tasks we fan out below.
    private let ciContext = SharedCIContext.shared

    func analyzePhotos(_ images: [UIImage]) async -> [PhotoScore] {
        await withTaskGroup(of: (Int, PhotoScore).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask { [weak self] in
                    var score = await self?.analyzePhoto(image) ?? PhotoScore(image: image, qualityScore: 0.3)
                    score.originalIndex = index
                    return (index, score)
                }
            }
            var results = [(Int, PhotoScore)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func analyzePhoto(_ image: UIImage) async -> PhotoScore {
        guard let cgImage = image.cgImage else {
            return PhotoScore(image: image, qualityScore: 0.3)
        }

        var qualityScore: Float = 0.5

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        var hasFace = false
        var faceCount = 0
        var isSmiling = false
        var genuineSmileScore: Float = 0.5
        var eyeState: EyeState = .unknown
        var eyesOpen = true
        var eyeOpenConfidence: Float = 0.5
        var eyeSymmetryScore: Float = 0.75
        var eyeOcclusionScore: Float = 0.0
        var faceYaw: Float = 0
        var faceBoundingBox: CGRect? = nil
        var hasAnimal = false
        var animalEyeConfidence: Float = 0.5
        var poseScore: Float = 0.5
        var subjectHeight: Float = 0.5
        var candidateFaceList: [CandidateFaceData] = []

        let animalRequest = VNDetectAnimalBodyPoseRequest()
        let bodyPoseRequest = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([landmarksRequest, animalRequest, bodyPoseRequest])

            // Human body pose — detect awkward stance, extreme tilt, or turned-away body.
            // We also derive subjectHeight from the same observation (head→ankle span)
            // so the keyword-gated "looks tall / full body" branch in BatchProcessor has
            // a value to work with — no extra Vision pass needed.
            if let bodyObs = bodyPoseRequest.results?.first {
                poseScore = computePoseScore(from: bodyObs)
                subjectHeight = computeSubjectHeight(from: bodyObs)
            }

            // Animal body pose — dogs and cats
            if let animalObs = animalRequest.results?.first {
                hasAnimal = true
                if let allPoints = try? animalObs.recognizedPoints(forGroupKey: VNRecognizedPointGroupKey(rawValue: "all")),
                   !allPoints.isEmpty {
                    // Average joint confidence: high = animal well-oriented/facing camera with open eyes
                    let confs = allPoints.values.map { Float($0.confidence) }
                    let avg = confs.reduce(0, +) / Float(confs.count)
                    // Boost slightly since partial detections are normal; clamp to 1.0
                    animalEyeConfidence = min(avg * 1.4, 1.0)
                } else {
                    animalEyeConfidence = min(Float(animalObs.confidence) * 1.2, 1.0)
                }
            }

            if let faces = landmarksRequest.results, !faces.isEmpty {
                hasFace = true
                faceCount = faces.count
                let avgConfidence = faces.map { $0.confidence }.reduce(0, +) / Float(faces.count)
                qualityScore = 0.5 + (avgConfidence * 0.5)

                if let dominant = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                    let smileScore = computeGenuineSmileScore(from: dominant)
                    isSmiling = smileScore > 0.55
                    genuineSmileScore = smileScore
                    faceYaw = dominant.yaw.map { abs($0.floatValue) } ?? 0
                    faceBoundingBox = dominant.boundingBox

                    // Eye verdict comes from the DOMINANT (largest) face only — the same face
                    // whose smile and yaw we read above. The largest face is overwhelmingly the
                    // photo's subject (selfie / portrait), so a stranger blinking in the
                    // background must never flag the subject's photo as "Eyes closed."
                    // When the user is NOT the largest face (a true group shot), BatchProcessor
                    // re-identifies the user's face via reference embeddings and overrides this
                    // verdict with their face's data — see identifyUserFaceIndex and the
                    // candidateFaces override.
                    let dominantVerdict = computeEyeState(from: dominant)
                    eyeState = dominantVerdict.state
                    eyeOpenConfidence = dominantVerdict.confidence
                    eyeSymmetryScore = dominantVerdict.symmetry
                    eyeOcclusionScore = dominantVerdict.occlusion
                    eyesOpen = eyeState == .open

                    // Still collect every significant face (>= 20% of the dominant face's area)
                    // so BatchProcessor can match them against the user's reference face
                    // embeddings and pick the user's actual face when they aren't the dominant one.
                    let dominantArea = dominant.boundingBox.width * dominant.boundingBox.height
                    let significantFaces = faces.filter {
                        ($0.boundingBox.width * $0.boundingBox.height) >= dominantArea * 0.20
                    }

                    // Collect per-face metrics for all significant faces (sorted largest first).
                    // BatchProcessor uses this to identify which face is the user when reference
                    // face embeddings exist, and overrides quality scores with the user's face data.
                    candidateFaceList = significantFaces
                        .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
                        .map { face in
                            let verdict = computeEyeState(from: face)
                            return CandidateFaceData(
                                boundingBox: face.boundingBox,
                                eyeState: verdict.state,
                                eyeOpenConfidence: verdict.confidence,
                                eyeSymmetryScore: verdict.symmetry,
                                eyeOcclusionScore: verdict.occlusion,
                                genuineSmileScore: computeGenuineSmileScore(from: face),
                                faceYaw: face.yaw.map { abs($0.floatValue) } ?? 0,
                                detectionConfidence: Float(face.confidence),
                                area: Float(face.boundingBox.width * face.boundingBox.height)
                            )
                        }
                }
            } else {
                qualityScore = 0.4
            }
        } catch {
            qualityScore = 0.3
        }

        // Subject-area sharpness: focus the Laplacian on the face region (with padding).
        // For non-face photos, fall back to a centre-weighted 60% crop.
        let sharpness: Float
        if let box = faceBoundingBox {
            sharpness = subjectSharpness(cgImage: cgImage, normalizedBox: box, padding: 0.15)
        } else {
            sharpness = centreSharpness(cgImage: cgImage)
        }
        qualityScore = (qualityScore * 0.65) + (sharpness * 0.35)

        // Exposure quality — penalise blown highlights and crushed blacks
        let expScore = exposureQuality(cgImage: cgImage)

        // Background sharpness — low bg + sharp face signals nice bokeh separation
        let bgSharpness: Float = faceBoundingBox.map {
            backgroundSharpness(cgImage: cgImage, faceBox: $0)
        } ?? 0.5

        // Color harmony — hue coherence of the image palette
        let harmonyScore = computeColorHarmony(cgImage: cgImage)

        // Composition — subject near rule-of-thirds power points (face-anchored).
        // Falls back to a centroid derived from the body-pose observation when no face
        // is present, so landscape/full-body shots still pick up rule-of-thirds credit.
        let compScore: Float
        if let box = faceBoundingBox {
            compScore = compositionScore(faceBox: box)
        } else if let bodyObs = bodyPoseRequest.results?.first,
                  let bodyCentroid = bodyCentroid(from: bodyObs) {
            compScore = compositionScore(faceBox: CGRect(
                x: bodyCentroid.x - 0.05,
                y: bodyCentroid.y - 0.05,
                width: 0.10,
                height: 0.10))
        } else {
            compScore = 0.5
        }

        // Vibe score — the "slight blur but nice vibes" aesthetic.
        // Rewards: warm/harmonious palette, soft background (bokeh-like),
        // moderate (not pixel-peeping) face sharpness. Penalises hard clinical
        // sharpness with bland colour. Always contributes a small weight.
        let vibe = computeVibeScore(
            harmony: harmonyScore,
            backgroundSharpness: bgSharpness,
            exposureScore: expScore,
            qualityScore: qualityScore,
            hasFace: hasFace
        )

        var result = PhotoScore(
            image: image,
            qualityScore: qualityScore,
            hasFace: hasFace,
            faceCount: faceCount,
            isSmiling: isSmiling,
            genuineSmileScore: genuineSmileScore,
            eyeState: eyeState,
            eyesOpen: eyesOpen,
            eyeOpenConfidence: eyeOpenConfidence,
            eyeSymmetryScore: eyeSymmetryScore,
            eyeOcclusionScore: eyeOcclusionScore,
            faceYaw: faceYaw,
            faceBoundingBox: faceBoundingBox,
            hasAnimal: hasAnimal,
            animalEyeConfidence: animalEyeConfidence,
            poseScore: poseScore,
            exposureScore: expScore,
            backgroundSharpness: bgSharpness,
            compositionScore: compScore,
            colorHarmonyScore: harmonyScore,
            subjectHeight: subjectHeight,
            vibeScore: vibe
        )
        result.candidateFaces = candidateFaceList
        return result
    }

    /// Recomputes the face-anchored geometric metrics for an arbitrary face box. Used after the user
    /// has been identified as a NON-dominant face in a group photo: analyzePhoto computed subject
    /// sharpness, composition, and background bokeh against the *largest* face, but those should
    /// reflect the USER's face. Returns nil when the image can't be decoded.
    nonisolated func userFaceMetrics(image: UIImage, normalizedFaceBox box: CGRect)
        -> (subjectSharpness: Float, composition: Float, backgroundSharpness: Float)? {
        guard let cgImage = image.cgImage else { return nil }
        return (
            subjectSharpness(cgImage: cgImage, normalizedBox: box, padding: 0.15),
            compositionScore(faceBox: box),
            backgroundSharpness(cgImage: cgImage, faceBox: box)
        )
    }

    // MARK: - Subject height (from body pose)

    /// Returns the head→ankle vertical span normalised to [0, 1] in image coordinates.
    /// 0.0 = no usable keypoints / partial torso; 1.0 = head-to-toe full-body.
    /// Uses the lowest-confidence-per-joint approach: if either head or ankle is unreliable,
    /// the value drops toward the neutral 0.5 default rather than producing a confident lie.
    func computeSubjectHeight(from observation: VNHumanBodyPoseObservation) -> Float {
        guard let points = try? observation.recognizedPoints(.all) else { return 0.5 }

        let headKeys: [VNHumanBodyPoseObservation.JointName] = [.nose, .neck]
        let footKeys: [VNHumanBodyPoseObservation.JointName] = [.leftAnkle, .rightAnkle]

        // Top: highest-y reliable head/neck keypoint
        let tops = headKeys.compactMap { points[$0] }.filter { $0.confidence > 0.3 }
        let bottoms = footKeys.compactMap { points[$0] }.filter { $0.confidence > 0.3 }

        guard let top = tops.max(by: { $0.location.y < $1.location.y }),
              let bot = bottoms.min(by: { $0.location.y < $1.location.y }) else {
            // No reliable head+foot pair → can't measure full body. Stay at neutral.
            return 0.5
        }

        // Vision body-pose y is normalised image-bottom-up in [0, 1].
        let span = Float(top.location.y - bot.location.y)
        return min(max(span, 0), 1)
    }

    /// Best-guess subject centroid from a body-pose observation, normalised in image coords (y-up).
    /// Falls back to nil when no reliable keypoints exist.
    private func bodyCentroid(from observation: VNHumanBodyPoseObservation) -> (x: CGFloat, y: CGFloat)? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        let usable = points.values.filter { $0.confidence > 0.3 }
        guard !usable.isEmpty else { return nil }
        let xs = usable.map { $0.location.x }
        let ys = usable.map { $0.location.y }
        return (xs.reduce(0, +) / CGFloat(xs.count), ys.reduce(0, +) / CGFloat(ys.count))
    }

    // MARK: - Vibe score

    /// Composite "slight blur but nice vibes" score in [0, 1].
    /// - Warm + harmonious palette pulls the score up.
    /// - Soft background (low backgroundSharpness) is rewarded — implies bokeh / depth.
    /// - Mid-range face sharpness is fine; only crushed-blurry photos are penalised.
    /// - Photos with no face still get a vibe value driven by harmony + exposure.
    func computeVibeScore(
        harmony: Float,
        backgroundSharpness: Float,
        exposureScore: Float,
        qualityScore: Float,
        hasFace: Bool
    ) -> Float {
        // Bokeh proxy: lower bg sharpness = more separation = more vibe.
        // Map [0, 1] → [1, 0] with a gentle squash so a fully-tack-sharp scene still gets ~0.3.
        let bokeh: Float = 1.0 - min(max(backgroundSharpness, 0), 1) * 0.7

        // Sharpness tolerance: only photos below 0.30 quality (clearly camera-shake blurry)
        // get a real penalty; the 0.30–0.70 band is treated as fully acceptable. This is
        // the "slight blur is fine" relaxation.
        let sharpnessOK: Float
        switch qualityScore {
        case ..<0.30: sharpnessOK = 0.4
        case 0.30..<0.70: sharpnessOK = 1.0
        default: sharpnessOK = 0.95
        }

        let base = (harmony * 0.40) + (exposureScore * 0.20) + (bokeh * 0.25) + (sharpnessOK * 0.15)
        // Faceless scenery shots benefit slightly from the "no portrait noise" bonus.
        let faceModifier: Float = hasFace ? 1.0 : 1.05
        return min(max(base * faceModifier, 0), 1)
    }

    // MARK: - Eye state (open / closed / unknown) + confidence

    /// Returns a verdict + confidence for the dominant face's eyes.
    ///
    /// Bails out to `.unknown` when the signal is geometrically unreliable — extreme yaw,
    /// missing/too-few landmarks, or a wide left/right asymmetry that can't be disambiguated.
    /// Uses the **minimum** EAR across detected eyes so a wink or half-closed eye is never
    /// averaged into a spurious "eyes open" verdict.
    func computeEyeState(from face: VNFaceObservation) -> (state: EyeState, confidence: Float, symmetry: Float, occlusion: Float) {
        let yaw = face.yaw.map { abs($0.floatValue) }
        let leftEAR  = eyeAspectRatio(face.landmarks?.leftEye)
        let rightEAR = eyeAspectRatio(face.landmarks?.rightEye)
        return VisionAnalyzer.eyeStateFromEARs(
            leftEAR: leftEAR,
            rightEAR: rightEAR,
            faceYaw: yaw,
            faceConfidence: Float(face.confidence),
            faceWidth: Float(face.boundingBox.width),
            faceHeight: Float(face.boundingBox.height)
        )
    }

    /// Eye Aspect Ratio — width and height of the eye-landmark cloud.
    /// Vision gives ~6 points per eye in normalized coords; we measure height from the
    /// middle 50% of x-range points so eye-corner landmarks don't flatten the reading.
    private func eyeAspectRatio(_ eye: VNFaceLandmarkRegion2D?) -> Float? {
        guard let eye = eye else { return nil }
        let pts = eye.normalizedPoints
        // Need enough points to form a real eye outline. Vision typically gives 6;
        // fewer than 4 means severe occlusion (hair, sunglasses) or a bad detection.
        guard pts.count >= 4 else { return nil }

        guard let minX = pts.map({ Float($0.x) }).min(),
              let maxX = pts.map({ Float($0.x) }).max() else { return nil }
        let width = maxX - minX
        guard width > 0.001 else { return nil }

        let midMin = minX + width * 0.25
        let midMax = maxX - width * 0.25
        let middlePts = pts.filter { Float($0.x) >= midMin && Float($0.x) <= midMax }
        let refPts = middlePts.isEmpty ? pts : middlePts

        guard let topY    = refPts.map({ Float($0.y) }).max(),
              let bottomY = refPts.map({ Float($0.y) }).min() else { return nil }
        let height = topY - bottomY
        return height / width
    }

    /// Pure decision function — takes the raw EARs and face metadata, returns a state + confidence.
    /// Extracted from `computeEyeState` so it can be unit-tested without a real VNFaceObservation.
    ///
    /// Decision rules, in order:
    /// 1. Low face-detection confidence or a tiny face crop → `.unknown`. Landmarks through tinted sunglasses
    ///    typically come with a depressed per-face confidence.
    /// 2. Extreme yaw (|yaw| > ~0.50 rad / ~29°) → `.unknown`. At profile angles the EAR
    ///    geometry collapses and a visible open eye can read as closed, or vice-versa.
    /// 3. No eye landmarks available → `.unknown`.
    /// 4. Single-eye readings can prove an eye is open, but they cannot prove both eyes are closed.
    /// 5. Large left/right EAR asymmetry → `.unknown`. One collapsed eye landmark next to a clearly
    ///    open eye is usually a wink, squint, occlusion, or bad landmark pass; for ranking, that is
    ///    too ambiguous to label as "Eyes closed."
    /// 6. A closed verdict requires both eyes to be consistently, confidently low. Otherwise the
    ///    middle band is `.unknown` so we don't make either claim.
    static func eyeStateFromEARs(
        leftEAR: Float?,
        rightEAR: Float?,
        faceYaw: Float?,
        faceConfidence: Float = 1.0,
        faceWidth: Float? = nil,
        faceHeight: Float? = nil
    ) -> (state: EyeState, confidence: Float, symmetry: Float, occlusion: Float) {
        let metrics = eyeSignalMetrics(
            leftEAR: leftEAR,
            rightEAR: rightEAR,
            faceYaw: faceYaw,
            faceConfidence: faceConfidence,
            faceWidth: faceWidth,
            faceHeight: faceHeight
        )

        // Guard: low face-detection quality. Vision tends to drop on faces with heavy tinted
        // sunglasses, strong hair occlusion, bad exposure, or noisy landmarks. False "closed"
        // labels are worse than uncertainty, so require a stronger face observation.
        guard faceConfidence >= 0.70 else { return (.unknown, 0.5, metrics.symmetry, metrics.occlusion) }

        // Guard: tiny faces don't have enough landmark detail to make an eye-state claim.
        if let faceWidth, let faceHeight, min(faceWidth, faceHeight) < 0.06 {
            return (.unknown, 0.5, metrics.symmetry, metrics.occlusion)
        }

        // Guard: extreme yaw. Beyond ~29° the visible eye's EAR is foreshortened and the
        // hidden eye's EAR is nonsense, so we refuse to claim either way.
        if let yaw = faceYaw, abs(yaw) > 0.50 {
            return (.unknown, 0.5, metrics.symmetry, metrics.occlusion)
        }

        let ears = [leftEAR, rightEAR].compactMap { $0 }
        guard !ears.isEmpty else { return (.unknown, 0.5, metrics.symmetry, metrics.occlusion) }

        let minEAR = ears.min()!
        let maxEAR = ears.max()!
        let asymmetry = maxEAR - minEAR
        let minConfidence = earToConfidence(minEAR)

        // A single visible eye can confirm an open-eye photo, but it cannot confidently prove the
        // user's eyes are closed. Missing one eye is usually profile, hair, glasses, or occlusion.
        if ears.count == 1 {
            return minEAR >= 0.22
                ? (.open, minConfidence, metrics.symmetry, metrics.occlusion)
                : (.unknown, minConfidence, metrics.symmetry, metrics.occlusion)
        }

        // Strong asymmetry is not enough evidence for "eyes closed". It can be a wink, uneven
        // squint, glasses glare, eyelashes, or a bad landmark pass. Stay silent instead.
        if ears.count == 2 && asymmetry > 0.10 {
            return (.unknown, minConfidence, metrics.symmetry, metrics.occlusion)
        }

        // Closed requires both eyes to be consistently low. This avoids punishing narrow eyes,
        // smiles, dark-scene landmark noise, or a single collapsed eye contour.
        if minEAR < 0.09 && maxEAR < 0.13 {
            return (.closed, minConfidence, metrics.symmetry, metrics.occlusion)
        }
        if minEAR < 0.20 {
            return (.unknown, minConfidence, metrics.symmetry, metrics.occlusion)
        }
        return (.open, minConfidence, metrics.symmetry, metrics.occlusion)
    }

    /// Pure quality metrics for eye landmarks, exposed for tests and for downstream scoring.
    /// `symmetry` catches mismatched eye readings; `occlusion` distinguishes hidden eyes from
    /// confidently closed eyes so sunglasses do not train the model as blinks.
    static func eyeSignalMetrics(
        leftEAR: Float?,
        rightEAR: Float?,
        faceYaw: Float?,
        faceConfidence: Float = 1.0,
        faceWidth: Float? = nil,
        faceHeight: Float? = nil
    ) -> (symmetry: Float, occlusion: Float) {
        let ears = [leftEAR, rightEAR].compactMap { $0 }
        let yaw = abs(faceYaw ?? 0)

        var occlusion: Float = 0.0
        if faceConfidence < 0.70 {
            occlusion = max(occlusion, 0.85)
        } else if faceConfidence < 0.82 {
            occlusion = max(occlusion, 0.45)
        }
        if let faceWidth, let faceHeight, min(faceWidth, faceHeight) < 0.06 {
            occlusion = max(occlusion, 0.80)
        }
        if yaw > 0.50 {
            occlusion = max(occlusion, 0.65)
        } else if yaw > 0.35 {
            occlusion = max(occlusion, 0.35)
        }

        switch ears.count {
        case 0:
            return (0.45, max(occlusion, 0.90))
        case 1:
            let oneEye = ears[0]
            let singleEyeOcclusion: Float = oneEye < 0.20 ? 0.78 : 0.62
            return (0.55, max(occlusion, singleEyeOcclusion))
        default:
            let minEAR = ears.min() ?? 0
            let maxEAR = ears.max() ?? 0
            let asymmetry = maxEAR - minEAR
            let symmetry = 1.0 - min(max((asymmetry - 0.03) / 0.12, 0), 1)
            if asymmetry > 0.10 {
                occlusion = max(occlusion, 0.58)
            } else if asymmetry > 0.07 {
                occlusion = max(occlusion, 0.32)
            }
            // Two consistently low EARs are a true closed-eye signal, not occlusion.
            if minEAR < 0.09 && maxEAR < 0.13 {
                occlusion = min(occlusion, 0.25)
            }
            return (min(max(symmetry, 0), 1), min(max(occlusion, 0), 1))
        }
    }

    /// Pure EAR → confidence mapping — exposed for unit testing.
    /// Thresholds calibrated for Vision framework landmarks, which produce lower EAR
    /// values than dlib-style landmarks (~0.12–0.22 for a naturally open eye).
    static func earToConfidence(_ ear: Float) -> Float {
        switch ear {
        case ..<0.08:         return 0.0           // definitely closed / hard blink
        case 0.08..<0.18:     return (ear - 0.08) / (0.18 - 0.08) * 0.5
        case 0.18..<0.30:     return 0.5 + (ear - 0.18) / (0.30 - 0.18) * 0.5
        default:              return 1.0           // clearly open
        }
    }

    // MARK: - Smile detection (Duchenne / genuine smile scoring)

    /// Returns a score representing smile genuineness:
    /// - 0.0 = no smile
    /// - 0.5 = ambiguous (possible squint) or lips-only with narrow range
    /// - 0.6 = lips-only smile (corner lift without eye involvement)
    /// - 1.0 = genuine Duchenne smile (lip lift + orbicularis oculi eye crinkle)
    private func computeGenuineSmileScore(from face: VNFaceObservation) -> Float {
        guard let landmarks = face.landmarks,
              let outerLips = landmarks.outerLips else { return 0.0 }

        let points = outerLips.normalizedPoints
        guard points.count >= 6 else { return 0.0 }

        guard let leftCorner   = points.min(by: { $0.x < $1.x }),
              let rightCorner  = points.max(by: { $0.x < $1.x }),
              let bottomCenter = points.min(by: { $0.y < $1.y }) else { return 0.0 }

        let avgCornerY = (leftCorner.y + rightCorner.y) / 2
        let lift = Float(avgCornerY - bottomCenter.y)

        // No lip corner lift — not smiling
        guard lift >= 0.03 else { return 0.0 }

        let leftEAR  = eyeAspectRatio(landmarks.leftEye)
        let rightEAR = eyeAspectRatio(landmarks.rightEye)

        let avgEAR: Float?
        switch (leftEAR, rightEAR) {
        case let (l?, r?): avgEAR = (l + r) / 2.0
        case let (l?, nil): avgEAR = l
        case let (nil, r?): avgEAR = r
        case (nil, nil): avgEAR = nil
        }

        guard let ear = avgEAR else {
            // No eye data — fall back to lip-lift only
            return lift > 0.05 ? 0.6 : 0.4
        }

        switch ear {
        case 0.14..<0.24 where lift > 0.05:
            // Slightly narrowed eyes + strong lip lift = genuine Duchenne smile
            return 1.0
        case 0.24..<0.35 where lift > 0.03:
            // Normal open eyes + lip lift = lips-only smile
            return 0.6
        case ..<0.14 where lift > 0.03:
            // Very narrow eyes with lip lift — ambiguous (could be squinting)
            return 0.5
        default:
            return lift > 0.05 ? 0.6 : 0.4
        }
    }

    // MARK: - Sharpness helpers

    /// Run Laplacian on the face bounding box (Vision normalised coords, y-up) with padding.
    private nonisolated func subjectSharpness(cgImage: CGImage, normalizedBox: CGRect, padding: CGFloat) -> Float {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        // Vision uses y-up; Core Graphics uses y-down — flip y
        let flippedY = 1.0 - normalizedBox.maxY
        var cropRect = CGRect(
            x: normalizedBox.minX * w,
            y: flippedY * h,
            width: normalizedBox.width * w,
            height: normalizedBox.height * h
        )
        // Expand by padding, clamped to image bounds
        cropRect = cropRect.insetBy(dx: -cropRect.width * padding, dy: -cropRect.height * padding)
        cropRect = cropRect.intersection(CGRect(x: 0, y: 0, width: w, height: h))

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return laplacianSharpness(cgImage: cgImage, roi: nil)
        }
        return laplacianSharpness(cgImage: cropped, roi: nil)
    }

    /// Fallback for non-face photos: measure sharpness on the central 60% of the image.
    private nonisolated func centreSharpness(cgImage: CGImage) -> Float {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let margin = CGFloat(0.20)
        let roi = CGRect(x: w * margin, y: h * margin,
                         width: w * (1 - margin * 2), height: h * (1 - margin * 2))
        guard let cropped = cgImage.cropping(to: roi) else {
            return laplacianSharpness(cgImage: cgImage, roi: nil)
        }
        return laplacianSharpness(cgImage: cropped, roi: nil)
    }

    private nonisolated func laplacianSharpness(cgImage: CGImage, roi: CGRect?) -> Float {
        let ciImage = CIImage(cgImage: cgImage)
        let context = SharedCIContext.shared

        guard let filter = CIFilter(name: "CIConvolution3X3") else { return 0.5 }

        let laplacian: [CGFloat] = [
            0, -1, 0,
           -1,  4, -1,
            0, -1, 0
        ]

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(values: laplacian, count: 9), forKey: "inputWeights")
        filter.setValue(0, forKey: "inputBias")

        guard let outputImage = filter.outputImage,
              let cgOutput = context.createCGImage(outputImage, from: ciImage.extent) else {
            return 0.5
        }

        let smallImage = CIImage(cgImage: cgOutput)
        guard let avgFilter = CIFilter(name: "CIAreaAverage",
              parameters: [kCIInputImageKey: smallImage,
                           kCIInputExtentKey: CIVector(cgRect: smallImage.extent)]),
              let avgOutput = avgFilter.outputImage else {
            return 0.5
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(avgOutput,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        let brightness = (Float(bitmap[0]) + Float(bitmap[1]) + Float(bitmap[2])) / (3.0 * 255.0)
        return min(brightness * 10, 1.0)
    }

    // MARK: - Body pose score (human)

    /// Scores how natural the person's pose looks.
    /// Uses shoulder symmetry and overall joint detection confidence as signals.
    /// Returns 0.5 (neutral) when no body is detected — avoids penalising non-portrait photos.
    private func computePoseScore(from obs: VNHumanBodyPoseObservation) -> Float {
        guard let points = try? obs.recognizedPoints(.all), !points.isEmpty else {
            return Float(obs.confidence) * 0.8
        }

        let confs = points.values.map { Float($0.confidence) }
        let avgConf = confs.reduce(0, +) / Float(confs.count)

        // Very low detection confidence: person likely turned away, heavily occluded, or
        // at a very unusual angle — all signs of a less-natural shot.
        guard avgConf > 0.18 else { return 0.30 }

        // Shoulder tilt: extreme lateral lean signals an awkward or unnatural body angle.
        // We use the ratio of vertical shoulder height difference to horizontal shoulder width.
        // 0.0 = perfectly level, ~0.5 = ~27° tilt, ~1.0 = ~45° tilt.
        var tiltPenalty: Float = 0.0
        if let ls = try? obs.recognizedPoint(.leftShoulder),
           let rs = try? obs.recognizedPoint(.rightShoulder),
           ls.confidence > 0.4, rs.confidence > 0.4 {
            let hWidth  = abs(Float(ls.location.x) - Float(rs.location.x))
            let vDiff   = abs(Float(ls.location.y) - Float(rs.location.y))
            let tiltRatio = hWidth > 0.02 ? vDiff / hWidth : 0.0
            if tiltRatio > 0.90 {
                tiltPenalty = 0.40   // extreme twist / awkward lean
            } else if tiltRatio > 0.55 {
                tiltPenalty = 0.20   // noticeable lean — may or may not be intentional
            }
        }

        // Map average confidence to a base score, then subtract tilt penalty.
        let base: Float = 0.55 + avgConf * 0.45   // range 0.55–1.00
        return max(base - tiltPenalty, 0.20)
    }

    // MARK: - Exposure quality

    /// Returns 1.0 for well-exposed images; lower for blown highlights or crushed blacks.
    private func exposureQuality(cgImage: CGImage) -> Float {
        let ciImage = CIImage(cgImage: cgImage)
        let context = ciContext

        guard let avg = CIFilter(name: "CIAreaAverage",
              parameters: [kCIInputImageKey: ciImage,
                           kCIInputExtentKey: CIVector(cgRect: ciImage.extent)]),
              let out = avg.outputImage else { return 0.5 }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &pixel,
                       rowBytes: 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        let lum = 0.299 * pixel[0] + 0.587 * pixel[1] + 0.114 * pixel[2]

        switch lum {
        case ..<0.06:          return 0.25  // severely underexposed / black
        case 0.06..<0.15:      return 0.60  // dark — may be intentional, mild penalty
        case 0.15..<0.78:      return 1.00  // well exposed
        case 0.78..<0.90:      return 0.75  // slightly bright
        default:               return 0.35  // overexposed / blown
        }
    }

    // MARK: - Background sharpness (bokeh detection)

    /// Measures sharpness in the image corners — areas unlikely to contain the portrait subject.
    /// Low background sharpness + high subject sharpness signals bokeh separation.
    private nonisolated func backgroundSharpness(cgImage: CGImage, faceBox: CGRect) -> Float {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let side = min(w, h) * 0.22

        // Four corner crops
        let corners = [
            CGRect(x: 0,        y: 0,        width: side, height: side),
            CGRect(x: w - side, y: 0,        width: side, height: side),
            CGRect(x: 0,        y: h - side, width: side, height: side),
            CGRect(x: w - side, y: h - side, width: side, height: side),
        ]

        // Convert Vision y-up face box to CG y-down for overlap check
        let facePixels = CGRect(x: faceBox.minX * w,
                                y: (1 - faceBox.maxY) * h,
                                width: faceBox.width * w,
                                height: faceBox.height * h)
            .insetBy(dx: -30, dy: -30)

        let usable = corners.filter { !$0.intersects(facePixels) }
        guard !usable.isEmpty else { return 0.5 }

        let values = usable.compactMap { rect -> Float? in
            guard let crop = cgImage.cropping(to: rect) else { return nil }
            return laplacianSharpness(cgImage: crop, roi: nil)
        }
        guard !values.isEmpty else { return 0.5 }
        return values.reduce(0, +) / Float(values.count)
    }

    // MARK: - Composition score (rule of thirds)

    /// Scores how close the face centre is to a rule-of-thirds power point.
    /// Vision coordinates are normalised (0–1, y-up).
    private nonisolated func compositionScore(faceBox: CGRect) -> Float {
        let cx = Float(faceBox.midX)
        let cy = Float(faceBox.midY)

        let powerPoints: [(Float, Float)] = [
            (1/3, 1/3), (2/3, 1/3), (1/3, 2/3), (2/3, 2/3),
            (0.5, 0.5)
        ]

        let minDist = powerPoints.map { pp -> Float in
            let dx = cx - pp.0; let dy = cy - pp.1
            return (dx * dx + dy * dy).squareRoot()
        }.min() ?? 1.0

        switch minDist {
        case ..<0.08:         return 1.00
        case 0.08..<0.17:     return 0.80
        case 0.17..<0.28:     return 0.60
        default:              return 0.35
        }
    }

    // MARK: - Color harmony scoring

    /// Scores the hue coherence of the image palette using circular statistics on a 6×6 sample grid.
    /// Returns 1.0 for analogous palettes, 0.9 for monochromatic, 0.75 for complementary,
    /// 0.5 for complex/artistic, and 0.3 for chaotic/clashing colour distributions.
    private func computeColorHarmony(cgImage: CGImage) -> Float {
        let ciImage = CIImage(cgImage: cgImage)
        let context = ciContext

        // Sample a 6x6 grid of points across the image for hue diversity
        let w = ciImage.extent.width
        let h = ciImage.extent.height
        var hues: [Float] = []

        let steps = 6
        for row in 0..<steps {
            for col in 0..<steps {
                let x = (CGFloat(col) + 0.5) / CGFloat(steps) * w
                let y = (CGFloat(row) + 0.5) / CGFloat(steps) * h
                let sampleRect = CGRect(x: x - 1, y: y - 1, width: 3, height: 3)
                    .intersection(ciImage.extent)
                guard sampleRect.width > 0, sampleRect.height > 0 else { continue }

                guard let avgFilter = CIFilter(name: "CIAreaAverage",
                      parameters: [kCIInputImageKey: ciImage,
                                   kCIInputExtentKey: CIVector(cgRect: sampleRect)]),
                      let out = avgFilter.outputImage else { continue }

                var pixel = [Float](repeating: 0, count: 4)
                context.render(out, toBitmap: &pixel,
                               rowBytes: 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf,
                               colorSpace: CGColorSpaceCreateDeviceRGB())

                let r = pixel[0], g = pixel[1], b = pixel[2]
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let delta = maxC - minC
                guard delta > 0.05 else { continue } // skip near-greyscale samples

                // Compute hue in [0, 360)
                var hue: Float
                if maxC == r      { hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
                else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
                else              { hue = 60 * ((r - g) / delta + 4) }
                if hue < 0 { hue += 360 }
                hues.append(hue)
            }
        }

        guard hues.count >= 4 else { return 0.5 } // not enough saturated pixels — neutral

        // Compute circular standard deviation of hues
        let rad = hues.map { $0 * Float.pi / 180 }
        let sinMean = rad.map { sin($0) }.reduce(0, +) / Float(rad.count)
        let cosMean = rad.map { cos($0) }.reduce(0, +) / Float(rad.count)
        let R = sqrt(sinMean * sinMean + cosMean * cosMean)  // 0 = random, 1 = all same hue
        // R close to 1 = monochromatic, R close to 0 = chaotic
        // Sweet spot: R in 0.4–0.8 = analogous/complementary palette
        switch R {
        case 0.55...:     return 0.90  // monochromatic — very cohesive
        case 0.35..<0.55: return 1.00  // analogous — ideal harmony
        case 0.20..<0.35: return 0.75  // complementary / split — still good
        case 0.10..<0.20: return 0.50  // complex — may work artistically
        default:          return 0.30  // very chaotic palette
        }
    }
}
