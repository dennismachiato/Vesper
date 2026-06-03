//
//  AppError.swift
//  Vesper
//
//  Central error type surfaced to the user. All errors should have a friendly
//  message — never show raw Swift error descriptions.
//

import Foundation

enum AppError: LocalizedError, Equatable {
    case modelUnavailable       // CLIP / CoreML model failed to load
    case noPhotosLoaded         // iCloud download failed for all photos
    case processingFailed       // Vision / scoring pipeline crashed
    case photoLibraryDenied     // Permission was revoked mid-session

    var errorDescription: String? { title }

    var title: String {
        switch self {
        case .modelUnavailable:   return "AI Model Unavailable"
        case .noPhotosLoaded:     return "Couldn't Load Photos"
        case .processingFailed:   return "Processing Failed"
        case .photoLibraryDenied: return "Photos Access Removed"
        }
    }

    var message: String {
        switch self {
        case .modelUnavailable:
            return "The on-device AI model couldn't start. Try closing other apps to free up memory, then try again."
        case .noPhotosLoaded:
            return "None of your selected photos could be downloaded. Check your internet connection if they're stored in iCloud."
        case .processingFailed:
            return "Something went wrong while ranking your photos. This is usually a memory issue — try selecting fewer photos."
        case .photoLibraryDenied:
            return "Vesper lost access to your photos. Go to Settings → Privacy & Security → Photos and allow access."
        }
    }

    var systemImage: String {
        switch self {
        case .modelUnavailable:   return "cpu.fill"
        case .noPhotosLoaded:     return "icloud.slash"
        case .processingFailed:   return "exclamationmark.triangle.fill"
        case .photoLibraryDenied: return "photo.badge.exclamationmark"
        }
    }
}
