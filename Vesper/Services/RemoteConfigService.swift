//
//  RemoteConfigService.swift
//  Vesper
//

import FirebaseRemoteConfig

@Observable
class RemoteConfigService {
    static let shared = RemoteConfigService()

    // Scoring weights — updated from Remote Config
    var qualityWeight: Float = 0.35
    var promptWeight: Float = 0.65
    var referenceWeight: Float = 0.40
    var feedbackBoostMax: Float = 1.6
    var feedbackBoostMin: Float = 0.4

    private let config = RemoteConfig.remoteConfig()

    private init() {
        // Set defaults so the app works even without network
        config.setDefaults([
            "quality_weight": NSNumber(value: 0.35),
            "prompt_weight": NSNumber(value: 0.65),
            "reference_weight": NSNumber(value: 0.40),
            "feedback_boost_max": NSNumber(value: 1.6),
            "feedback_boost_min": NSNumber(value: 0.4)
        ])
    }

    func fetch() async {
        do {
            let status = try await config.fetchAndActivate()
            if status == .successFetchedFromRemote || status == .successUsingPreFetchedData {
                applyValues()
            }
        } catch {
            // Use defaults silently — app still works
        }
    }

    private func applyValues() {
        qualityWeight = Self.clamp(config["quality_weight"].numberValue.floatValue, min: 0.0, max: 1.0, fallback: 0.35)
        promptWeight = Self.clamp(config["prompt_weight"].numberValue.floatValue, min: 0.0, max: 1.0, fallback: 0.65)
        referenceWeight = Self.clamp(config["reference_weight"].numberValue.floatValue, min: 0.0, max: 0.60, fallback: 0.40)

        let minBoost = Self.clamp(config["feedback_boost_min"].numberValue.floatValue, min: 0.20, max: 1.0, fallback: 0.4)
        let maxBoost = Self.clamp(config["feedback_boost_max"].numberValue.floatValue, min: 1.0, max: 2.0, fallback: 1.6)
        feedbackBoostMin = minBoost
        feedbackBoostMax = max(maxBoost, minBoost)
    }

    nonisolated static func clamp(_ value: Float, min lower: Float, max upper: Float, fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
