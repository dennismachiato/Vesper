//
//  VesperUITests.swift
//  VesperUITests
//
//  XCUITest is the iOS-native equivalent of Playwright (which is web-only).
//  These tests drive the real app from the outside — launching it, tapping
//  controls, asserting on rendered text. Deep navigation past the photo
//  picker is impractical (PhotosPicker is a system UI we can't drive
//  reliably from XCUITest), so coverage focuses on:
//    1. The app launches without crashing.
//    2. The home screen renders its core surface.
//    3. The "New Batch" entry point is reachable.
//

import XCTest

final class VesperUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-uiTestingSkipOnboarding")
        return app
    }

    @MainActor
    func test_appLaunchesAndRendersHomeSurface() throws {
        let app = makeApp()
        app.launch()

        // Title text — primary signal that the home view rendered.
        XCTAssertTrue(app.staticTexts["Vesper"].waitForExistence(timeout: 5),
            "Home screen should render the 'Vesper' title within 5s of launch")

        // Tagline — second-level signal that the home view's full layout is present.
        XCTAssertTrue(app.staticTexts["Find your best shots"].exists,
            "Home tagline should render alongside the title")
    }

    @MainActor
    func test_newBatchEntryPoint_existsAndIsTappable() throws {
        let app = makeApp()
        app.launch()

        let newBatchButton = app.buttons["New Batch"]
        XCTAssertTrue(newBatchButton.waitForExistence(timeout: 5),
            "Home screen should expose a 'New Batch' button as the primary action")
        XCTAssertTrue(newBatchButton.isHittable,
            "'New Batch' button should be hittable, not occluded")
    }

    @MainActor
    func test_aiTrainingEntryPoint_existsAndIsTappable() throws {
        let app = makeApp()
        app.launch()

        let trainingButton = app.buttons["Test the AI Model"]
        XCTAssertTrue(trainingButton.waitForExistence(timeout: 5),
            "Home screen should expose a training entry point")
        XCTAssertTrue(trainingButton.isHittable,
            "'Test the AI Model' button should be hittable, not occluded")
    }

    @MainActor
    func test_cleanupEntryPoint_existsAndIsTappable() throws {
        let app = makeApp()
        app.launch()

        let cleanupButton = app.buttons["Full Library Cleanup"]
        XCTAssertTrue(cleanupButton.waitForExistence(timeout: 5),
            "Home screen should expose a cleanup entry point")
        XCTAssertTrue(cleanupButton.isHittable,
            "'Full Library Cleanup' button should be hittable, not occluded")
    }

    @MainActor
    func test_styleProfileEntryPoint_isReachable() throws {
        let app = makeApp()
        app.launch()

        // Either the empty-state CTA ("Set up your style") or the populated one ("Your style")
        // should appear, depending on whether the user has any reference photos in the store.
        let setupCTA = app.staticTexts["Set up your style"]
        let yourStyle = app.staticTexts["Your style"]

        let appearedInTime = setupCTA.waitForExistence(timeout: 3) || yourStyle.exists
        XCTAssertTrue(appearedInTime,
            "Home should expose either 'Set up your style' or 'Your style' so the user can manage references")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Tracks regression in cold-launch time. Anything > a couple of seconds
        // means a startup-time regression worth investigating.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = makeApp()
            app.launch()
        }
    }
}
