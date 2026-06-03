//
//  CleanUpCategory.swift
//  Vesper
//
//  Models for the library-wide cleanup feature. Each CleanUpCategory
//  represents a kind of "probably deletable" photo/video, and
//  CleanUpGroup collects the assets that matched.
//

import Photos

// MARK: - Category definition

enum CleanUpCategory: String, CaseIterable, Identifiable {
    case screenshots
    case screenRecordings
    case similarPhotos
    case blurry
    case receipts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots:      return "Screenshots"
        case .screenRecordings: return "Screen Recordings"
        case .similarPhotos:    return "Similar Photos"
        case .blurry:           return "Blurry Photos"
        case .receipts:         return "Receipts & Documents"
        }
    }

    var icon: String {
        switch self {
        case .screenshots:      return "rectangle.on.rectangle"
        case .screenRecordings: return "record.circle"
        case .similarPhotos:    return "square.stack.3d.down.right"
        case .blurry:           return "camera.metering.unknown"
        case .receipts:         return "doc.text"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshots:      return "Saved screen captures"
        case .screenRecordings: return "Recorded screen videos"
        case .similarPhotos:    return "Burst-like duplicates taken moments apart"
        case .blurry:           return "Out of focus or motion-blurred shots"
        case .receipts:         return "Text-heavy images like receipts, menus, bills"
        }
    }

    /// Sort order — metadata-only categories first (instant), AI-backed last (progressive).
    var sortOrder: Int {
        switch self {
        case .screenshots:      return 0
        case .screenRecordings: return 1
        case .similarPhotos:    return 2
        case .blurry:           return 3
        case .receipts:         return 4
        }
    }
}

// MARK: - Result group

/// All assets that matched a single category, along with their aggregate file size.
struct CleanUpGroup: Identifiable {
    let id: String   // reuse category rawValue for stable identity
    let category: CleanUpCategory
    var assets: [PHAsset]
    var totalSizeBytes: Int64
    /// True while this category is still being scanned
    var isScanning: Bool

    /// For similar-photos: clusters of asset identifiers that belong together
    /// (e.g., 4 burst-like shots taken in the same second). nil for other categories.
    var clusters: [[PHAsset]]?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    var count: Int { assets.count }
}
