//
//  CLIPTextEmbedder.swift
//  Vesper
//

import CoreML
import Foundation

class CLIPTextEmbedder {
    static let shared: CLIPTextEmbedder? = CLIPTextEmbedder()

    private let model: mobileclip_s0_text
    private let tokenizer = CLIPTokenizer()
    /// Serializes calls into Core ML — MLModel prediction is not thread-safe
    /// under concurrent invocation. Also protects the tokenizer's BPE cache.
    private let predictionQueue = DispatchQueue(label: "app.vesper.clip-text-embedder")

    init?() {
        guard let model = try? mobileclip_s0_text() else { return nil }
        self.model = model
    }

    /// Returns an averaged, normalized embedding across 4 prompt templates.
    /// Averaging multiple phrasings of the same intent significantly improves CLIP retrieval
    /// accuracy by centering the query vector on the concept rather than literal wording.
    func embedWithTemplates(prompt: String) -> [Float]? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        let templates = [
            p,
            "a photo of \(p)",
            "a high quality photo of \(p)",
            "\(p), professional photography"
        ]
        let embeddings = templates.compactMap { embed(prompt: $0) }
        guard !embeddings.isEmpty else { return nil }
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings { for i in 0..<dim { avg[i] += emb[i] } }
        let count = Float(embeddings.count)
        avg = avg.map { $0 / count }
        return normalized(avg)
    }

    // Returns a normalized 512-dim embedding for the given text prompt, or nil on failure
    func embed(prompt: String) -> [Float]? {
        // Both tokenization (mutable BPE cache) and prediction (non-thread-safe MLModel)
        // must be serialized. Do it all inside the queue so callers can fan out freely.
        return predictionQueue.sync {
            embedOnPredictionQueue(prompt: prompt)
        }
    }

    // Async version — suspends the caller while tokenization and prediction run
    // on the serial Core ML queue. Useful from UI actions where a sync prediction
    // would otherwise hitch the main thread.
    func embedAsync(prompt: String) async -> [Float]? {
        await withCheckedContinuation { continuation in
            predictionQueue.async { [self] in
                continuation.resume(returning: embedOnPredictionQueue(prompt: prompt))
            }
        }
    }

    private func embedOnPredictionQueue(prompt: String) -> [Float]? {
        let tokens = tokenizer.tokenize(prompt)

        // Build MLMultiArray of shape [1, 77] with Int32 values
        guard let inputArray = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
        for (i, token) in tokens.enumerated() {
            inputArray[i] = NSNumber(value: token)
        }

        guard let output = try? model.prediction(text: inputArray) else { return nil }

        let embedding = output.final_emb_1
        let count = embedding.count
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = embedding[i].floatValue
        }
        return normalized(result)
    }

    private func normalized(_ v: [Float]) -> [Float] {
        let magnitude = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 1e-8 else { return v }
        return v.map { $0 / magnitude }
    }
}
