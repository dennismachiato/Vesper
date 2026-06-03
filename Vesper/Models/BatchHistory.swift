//
//  BatchHistory.swift
//  Vesper

import SwiftData
import UIKit

@Model
class BatchHistory {
    var createdAt: Date
    var category: String        // PhotoCategory.rawValue or "" for prompt mode
    var aesthetic: String       // AestheticStyle.rawValue or "" for prompt mode
    var promptText: String      // non-empty when isPromptMode
    var isPromptMode: Bool
    var pickCount: Int
    var totalPhotos: Int
    var customName: String = "" // user-assigned label; overrides the auto-generated label when set
    // Up to 4 top-pick thumbnails stored as JPEG Data (small, ~150px)
    var thumbnail0: Data?
    var thumbnail1: Data?
    var thumbnail2: Data?
    var thumbnail3: Data?
    // V6: PHAsset localIdentifiers as JSON [String] — used for rerunning a batch
    var assetIdentifiersData: Data? = nil
    // V6: Purpose tag for re-filtering feedback on rerun
    var purposeTag: String = ""

    init(
        category: String,
        aesthetic: String,
        promptText: String,
        isPromptMode: Bool,
        pickCount: Int,
        totalPhotos: Int,
        thumbnails: [UIImage],
        assetIdentifiers: [String] = [],
        purposeTag: String = ""
    ) {
        self.createdAt    = Date()
        self.category     = category
        self.aesthetic    = aesthetic
        self.promptText   = promptText
        self.isPromptMode = isPromptMode
        self.pickCount    = pickCount
        self.totalPhotos  = totalPhotos
        self.purposeTag   = purposeTag

        func jpeg(_ img: UIImage?) -> Data? {
            guard let img else { return nil }
            let side: CGFloat = 150
            let scale = side / max(img.size.width, img.size.height)
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            return UIGraphicsImageRenderer(size: size).image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.6)
        }

        thumbnail0 = jpeg(thumbnails.count > 0 ? thumbnails[0] : nil)
        thumbnail1 = jpeg(thumbnails.count > 1 ? thumbnails[1] : nil)
        thumbnail2 = jpeg(thumbnails.count > 2 ? thumbnails[2] : nil)
        thumbnail3 = jpeg(thumbnails.count > 3 ? thumbnails[3] : nil)

        if !assetIdentifiers.isEmpty {
            assetIdentifiersData = try? JSONEncoder().encode(assetIdentifiers)
        }
    }

    var thumbnails: [UIImage] {
        [thumbnail0, thumbnail1, thumbnail2, thumbnail3]
            .compactMap { $0 }
            .compactMap { UIImage(data: $0) }
    }

    var storedAssetIdentifiers: [String] {
        guard let data = assetIdentifiersData,
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    var isDatingMode: Bool { category == "Dating" }

    /// Short label shown in the history list — custom name takes priority
    var label: String {
        if !customName.isEmpty { return customName }
        if isPromptMode {
            return promptText.isEmpty ? "Prompt mode" : "\"\(promptText)\""
        }
        return category.isEmpty ? aesthetic : category
    }
}
