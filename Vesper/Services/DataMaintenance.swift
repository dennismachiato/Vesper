//
//  DataMaintenance.swift
//  Vesper
//
//  Lightweight housekeeping that runs once per app launch:
//    - Prunes BatchHistory older than a retention window
//    - Caps PhotoFeedback at a maximum count (keeps the most recent)
//
//  All pruning is local-only and non-blocking. A Firebase Remote Config knob
//  can override the thresholds, but sensible defaults ship in code.
//

import Foundation
import SwiftData
import OSLog

enum DataMaintenance {
    private nonisolated static var logger: Logger {
        Logger(subsystem: "Vesper", category: "DataMaintenance")
    }

    /// Oldest allowable BatchHistory record (180 days by default).
    nonisolated static let historyRetentionDays: Int = 180
    /// Maximum number of PhotoFeedback records kept on-device.
    /// 2,000 covers roughly a year of heavy use; older entries are pruned.
    nonisolated static let feedbackRetentionCount: Int = 2_000

    /// Runs pruning synchronously inside the given ModelContext. Safe to call
    /// on a background actor — each pass uses its own FetchDescriptor so we
    /// never hold a large object graph in memory.
    nonisolated static func prune(in context: ModelContext) {
        pruneBatchHistory(in: context)
        capFeedback(in: context)
        do {
            try context.save()
        } catch {
            logger.error("Save after prune failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private nonisolated static func pruneBatchHistory(in context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(historyRetentionDays) * 86_400)
        let descriptor = FetchDescriptor<BatchHistory>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for item in stale { context.delete(item) }
        logger.info("Pruned \(stale.count, privacy: .public) batch history records older than \(historyRetentionDays, privacy: .public)d")
    }

    private nonisolated static func capFeedback(in context: ModelContext) {
        let descriptor = FetchDescriptor<PhotoFeedback>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let all = try? context.fetch(descriptor), all.count > feedbackRetentionCount else { return }
        let excess = Array(all.dropFirst(feedbackRetentionCount))
        for item in excess { context.delete(item) }
        logger.info("Pruned \(excess.count, privacy: .public) feedback records over cap of \(feedbackRetentionCount, privacy: .public)")
    }
}
