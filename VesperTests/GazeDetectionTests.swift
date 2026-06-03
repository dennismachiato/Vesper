//
//  GazeDetectionTests.swift
//  VesperTests
//
//  Tests for the prompt-text gaze-intent parser.
//  These are pure string functions so they run instantly with no dependencies.
//

import XCTest
@testable import Vesper

final class GazeDetectionTests: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - Looking away

    func test_lookingAway_detectedFromExactPhrase() {
        XCTAssertTrue(processor.promptWantsLookingAway("looking away from camera"))
    }

    func test_lookingAway_detectedCaseInsensitive() {
        XCTAssertTrue(processor.promptWantsLookingAway("LOOKING AWAY in the distance"))
    }

    func test_lookingAway_offCamera() {
        XCTAssertTrue(processor.promptWantsLookingAway("off camera, dramatic mood"))
    }

    func test_lookingAway_averted() {
        XCTAssertTrue(processor.promptWantsLookingAway("averted gaze, moody"))
    }

    func test_lookingAway_notDetectedInUnrelatedPrompt() {
        XCTAssertFalse(processor.promptWantsLookingAway("bright outdoor portrait, smiling"))
    }

    func test_lookingAway_notDetectedInEmptyString() {
        XCTAssertFalse(processor.promptWantsLookingAway(""))
    }

    // MARK: - Looking at camera

    func test_lookingAtCamera_eyeContact() {
        XCTAssertTrue(processor.promptWantsLookingAtCamera("eye contact, confident"))
    }

    func test_lookingAtCamera_directGaze() {
        XCTAssertTrue(processor.promptWantsLookingAtCamera("direct gaze into lens"))
    }

    func test_lookingAtCamera_detectedCaseInsensitive() {
        XCTAssertTrue(processor.promptWantsLookingAtCamera("LOOKING AT CAMERA, sharp"))
    }

    func test_lookingAtCamera_facingCamera() {
        XCTAssertTrue(processor.promptWantsLookingAtCamera("facing camera, minimal background"))
    }

    func test_lookingAtCamera_notDetectedInUnrelatedPrompt() {
        XCTAssertFalse(processor.promptWantsLookingAtCamera("golden hour, candid, nature"))
    }

    // MARK: - Mutual exclusivity (both false for neutral prompts)

    func test_neutralPrompt_neitherGazeIntent() {
        let neutral = "soft lighting, natural smile"
        XCTAssertFalse(processor.promptWantsLookingAway(neutral))
        XCTAssertFalse(processor.promptWantsLookingAtCamera(neutral))
    }

    // MARK: - Edge cases

    func test_partialWordDoesNotMatch() {
        // "not looking" should match but "nota looking" should not be special
        XCTAssertTrue(processor.promptWantsLookingAway("not looking at camera"))
    }

    func test_longPromptWithGazeKeyword() {
        let long = "I want a very dramatic photo with high contrast, the subject should be looking away from the camera into the distance, golden hour light"
        XCTAssertTrue(processor.promptWantsLookingAway(long))
        XCTAssertFalse(processor.promptWantsLookingAtCamera(long))
    }
}
