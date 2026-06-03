//
//  ReferencePhoto.swift
//  Vesper
//

import SwiftData
import UIKit

@Model
class ReferencePhoto {
    // All stored properties have defaults so SwiftData migration never fails
    // on an older store that's missing a column; values are always overwritten
    // by init().
    var thumbnailData: Data = Data()
    var brightness: Float = 0.5
    var saturation: Float = 0.5
    var warmth: Float = 0.5
    // These three fields were added after initial release.
    // SwiftData will set them to the default values below on existing records.
    var contrast: Float = 0.5       // std dev of grayscale — how punchy vs. flat
    var sharpness: Float = 0.5      // Laplacian variance normalized — crisp vs. soft
    var avgFaceYaw: Float = 0.0     // 0 = facing camera, higher = turned away
    var faceCount: Int = 0
    var embeddingData: Data = Data()  // serialized [Float] — 512 floats from MobileCLIP (full image)
    var createdAt: Date = Date()
    // V7: CLIP embedding of the cropped dominant face region — used to identify the user's face
    // in group/multi-person batch photos. Nil for reference photos without a detected face.
    var faceCropEmbeddingData: Data? = nil
    // V8: CLIP embeddings of EVERY detected face crop in this reference (not just the dominant
    // one). References can be IG photos / screenshots where the user isn't the biggest face, so
    // the user is identified as the face that recurs across references — which needs all faces.
    // Serialized as: Int32 faceCount, Int32 dim, then faceCount*dim Float32s. Nil on old records.
    var allFaceCropEmbeddingsData: Data? = nil

    init(
        thumbnailData: Data,
        brightness: Float,
        saturation: Float,
        warmth: Float,
        contrast: Float = 0.5,
        sharpness: Float = 0.5,
        avgFaceYaw: Float = 0.0,
        faceCount: Int,
        embedding: [Float],
        faceCropEmbedding: [Float] = [],
        allFaceCropEmbeddings: [[Float]] = []
    ) {
        self.thumbnailData = thumbnailData
        self.brightness    = brightness
        self.saturation    = saturation
        self.warmth        = warmth
        self.contrast      = contrast
        self.sharpness     = sharpness
        self.avgFaceYaw    = avgFaceYaw
        self.faceCount     = faceCount
        self.embeddingData = embedding.withUnsafeBytes { Data($0) }
        self.createdAt     = Date()
        if !faceCropEmbedding.isEmpty {
            self.faceCropEmbeddingData = faceCropEmbedding.withUnsafeBytes { Data($0) }
        }
        let nonEmptyFaces = allFaceCropEmbeddings.filter { !$0.isEmpty }
        if !nonEmptyFaces.isEmpty {
            self.allFaceCropEmbeddingsData = ReferencePhoto.encodeFaceEmbeddings(nonEmptyFaces)
        }
    }

    var thumbnail: UIImage? { UIImage(data: thumbnailData) }

    var embedding: [Float] {
        embeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// CLIP embedding of the dominant face crop, or [] if not yet computed or no face detected.
    /// Used to identify the user's face in multi-person batch photos.
    var faceCropEmbedding: [Float] {
        guard let data = faceCropEmbeddingData else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// CLIP embeddings of every detected face crop in this reference. Falls back to the single
    /// dominant crop for records saved before V8 (so clustering still has something to work with).
    var allFaceCropEmbeddings: [[Float]] {
        guard let data = allFaceCropEmbeddingsData else {
            let dominant = faceCropEmbedding
            return dominant.isEmpty ? [] : [dominant]
        }
        return ReferencePhoto.decodeFaceEmbeddings(data)
    }

    // MARK: - [[Float]] serialization

    private static func encodeFaceEmbeddings(_ faces: [[Float]]) -> Data {
        var data = Data()
        var count = Int32(faces.count)
        var dim   = Int32(faces.first?.count ?? 0)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dim)   { data.append(contentsOf: $0) }
        for face in faces {
            face.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeFaceEmbeddings(_ data: Data) -> [[Float]] {
        let headerSize = MemoryLayout<Int32>.size * 2
        guard data.count >= headerSize else { return [] }
        return data.withUnsafeBytes { raw -> [[Float]] in
            let count = Int(raw.load(fromByteOffset: 0, as: Int32.self))
            let dim   = Int(raw.load(fromByteOffset: MemoryLayout<Int32>.size, as: Int32.self))
            guard count > 0, dim > 0,
                  data.count >= headerSize + count * dim * MemoryLayout<Float>.size,
                  let baseAddress = raw.baseAddress else { return [] }
            let floats = baseAddress.advanced(by: headerSize)
                .assumingMemoryBound(to: Float.self)
            var result: [[Float]] = []
            result.reserveCapacity(count)
            for i in 0..<count {
                result.append(Array(UnsafeBufferPointer(start: floats + i * dim, count: dim)))
            }
            return result
        }
    }
}
