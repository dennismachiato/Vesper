//
//  CategoryScorer.swift
//  Vesper
//

import Vision
import UIKit

class CategoryScorer {
    func score(image: UIImage, category: PhotoCategory) async -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let results = request.results else { return 0.5 }

            let keywords = categoryKeywords(for: category)
            var bestMatch: Float = 0

            for observation in results where observation.confidence > 0.1 {
                let id = observation.identifier.lowercased()
                for keyword in keywords {
                    if id.contains(keyword) {
                        bestMatch = max(bestMatch, observation.confidence)
                    }
                }
            }

            return bestMatch > 0 ? min(0.3 + bestMatch * 0.7, 1.0) : 0.3
        } catch {
            return 0.5
        }
    }

    private func categoryKeywords(for category: PhotoCategory) -> [String] {
        switch category {
        case .mugshot:
            // Clear portraits — face front and center, sharp, well-lit
            return ["person", "face", "portrait", "selfie", "head", "human", "smile", "woman", "man", "girl", "boy"]

        case .vacation:
            // Location, travel, being somewhere new — people + place together is fine
            return ["outdoor", "travel", "landscape", "beach", "sky", "water", "architecture", "tourism",
                    "ocean", "mountain", "city", "landmark", "vacation", "holiday", "pool", "sunset", "sunrise"]

        case .concert:
            // Energy, performance, atmosphere — crowd and stage vibes
            return ["performance", "music", "concert", "entertainment", "stage", "crowd", "event",
                    "festival", "band", "microphone", "spotlight", "musician", "singer", "audience",
                    "nightlife", "show", "live"]

        case .nature:
            // Pure environment — no people needed, night scenes valid
            return ["nature", "plant", "animal", "outdoor", "sky", "water", "landscape", "flower",
                    "tree", "forest", "night", "star", "moon", "mountain", "field", "grass",
                    "scenery", "scenic", "wilderness", "lake", "river", "ocean", "cloud",
                    "sunset", "sunrise", "wildlife", "bird", "leaf", "rock", "trail"]

        case .edgy:
            // Dark, dramatic, urban, raw — shadows, grit, attitude
            return ["night", "dark", "urban", "street", "graffiti", "monochrome", "building",
                    "shadow", "silhouette", "dramatic", "alley", "industrial", "city", "neon",
                    "underground", "smoke", "fog", "black", "contrast", "gritty"]
        }
    }
}
