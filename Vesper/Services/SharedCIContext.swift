//
//  SharedCIContext.swift
//  Vesper
//
//  A single process-wide CIContext. Allocating a fresh CIContext per call
//  spins up GPU resources and a Metal command queue every time — cheap in
//  isolation but a measurable drag during batch scoring where several
//  scorers hit it concurrently for each photo. Using one shared instance
//  lets Core Image pool buffers and keep the Metal pipeline warm.
//
//  The context itself is thread-safe for render calls.
//

import CoreImage

enum SharedCIContext {
    /// Process-wide CIContext. Default options are fine — we never need a
    /// specific color space / working format for the simple CIAreaAverage and
    /// Laplacian passes we run.
    nonisolated static let shared: CIContext = CIContext(options: nil)
}
