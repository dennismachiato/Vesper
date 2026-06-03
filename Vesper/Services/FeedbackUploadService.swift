//
//  FeedbackUploadService.swift
//  Vesper
//

import FirebaseFirestore
import UIKit
import OSLog

private let feedbackUploadLogger = Logger(subsystem: "Vesper", category: "FeedbackUpload")

class FeedbackUploadService {
    static let shared = FeedbackUploadService()
    private let db = Firestore.firestore()
    private var recentUploads: [Date] = []
    private let maxUploadsPerMinute = 10
    private init() {}

    /// Upload anonymous feedback. photoThumbnailData only included if user opted in.
    func upload(
        liked: Bool,
        reason: String,
        category: String,
        aesthetic: String,
        promptText: String,
        isPromptMode: Bool,
        qualityScore: Float,
        promptScore: Float?,
        referenceScore: Float?,
        feedbackScore: Float?,
        photoThumbnail: UIImage? = nil
    ) {
        // Client-side rate limiting: max 10 uploads per minute
        let now = Date()
        recentUploads.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentUploads.count < maxUploadsPerMinute else { return }
        recentUploads.append(now)

        // Input validation: cap string lengths to prevent abuse
        let safeReason   = String(reason.prefix(500))
        let safeCategory = String(category.prefix(50))
        let safeAesthetic = String(aesthetic.prefix(100))
        let safePrompt   = String(promptText.prefix(200))
        let safeQuality  = qualityScore.isFinite ? min(max(qualityScore, 0), 1) : 0.5

        var data: [String: Any] = [
            "liked": liked,
            "reason": safeReason,
            "category": safeCategory,
            "aesthetic": safeAesthetic,
            "promptText": safePrompt,
            "isPromptMode": isPromptMode,
            "qualityScore": safeQuality,
            "timestamp": FieldValue.serverTimestamp(),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]

        if let ps = promptScore, ps.isFinite { data["promptScore"] = min(max(ps, 0), 1) }
        if let rs = referenceScore, rs.isFinite { data["referenceScore"] = min(max(rs, 0), 1) }
        if let fs = feedbackScore, fs.isFinite { data["feedbackScore"] = min(max(fs, 0), 1) }

        // Optional low-res thumbnail (only if user opted in), capped at 100KB
        if let thumb = photoThumbnail,
           let jpeg = thumb.jpegData(compressionQuality: 0.4),
           jpeg.count < 100_000 {
            data["thumbnailBase64"] = jpeg.base64EncodedString()
        }

        db.collection("feedback").addDocument(data: data) { error in
            if let error = error {
                feedbackUploadLogger.error("Feedback upload failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
