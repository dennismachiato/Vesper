//
//  AppStartupTests.swift
//  VesperTests
//
//  Startup coverage for the SwiftData model-container path used by VesperApp.
//

import XCTest
import SwiftData
@testable import Vesper

final class AppStartupTests: XCTestCase {
    func test_appModelContainerFactory_createsInMemoryContainerUsingProductionPath() throws {
        let container = try VesperApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        assertEmpty(container)
    }

    private func assertEmpty(_ container: ModelContainer) {
        let context = ModelContext(container)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<ReferencePhoto>())) ?? -1, 0)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<PhotoFeedback>())) ?? -1, 0)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<BatchHistory>())) ?? -1, 0)
    }
}
