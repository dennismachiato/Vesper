//
//  PhotoLibraryService.swift
//  Vesper
//
//  Created by Dennis Mach on 4/1/26.
//

import Photos
import SwiftUI
import Observation

@Observable
class PhotoLibraryService {
    var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    /// Notified when library contents change (including revocations of "Limited" access).
    /// Registered once in init; held so we can keep the change observer alive.
    private var changeObserver: LibraryChangeObserver?

    init() {
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        self.changeObserver = observer
        PHPhotoLibrary.shared().register(observer)
    }

    deinit {
        if let observer = changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        }
    }

    func requestPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
        }
    }

    /// Pull the current authorization status again — call after returning from
    /// Settings, or when the user might have revoked access mid-batch.
    @MainActor
    func refreshStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    /// True when the user chose "Select Photos…" — some flows may want to show
    /// a "Manage selection" affordance separately from full-library access.
    var isLimited: Bool {
        authorizationStatus == .limited
    }
}

/// Bridges PHPhotoLibraryChangeObserver (Objective-C protocol on NSObject)
/// into a simple closure the Swift-side service can hold onto.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
