//
//  AestheticTrendTests.swift
//  VesperTests
//
//  Covers the four feature additions:
//   1. Reference-driven mode boosts the dynamic reference weight cap.
//   2. Subject-height bonus is gated on the "tall / full body" prompt keywords —
//      tall subjects rank higher when the user asked for them, and headshots are
//      NOT penalised when they didn't.
//   3. Vibe bonus rewards the "slight blur but nice vibes" aesthetic.
//   4. Trend bonus pulls modern-looking shots up when quality alone doesn't differentiate.
//

import XCTest
@testable import Vesper

final class AestheticTrendTests: XCTestCase {

    let processor = BatchProcessor()

    // MARK: - 1. Subject-height keyword gate

    func test_tallSubjectBonus_onlyAppliesWhenPromptAsksForIt() {
        // Same photo, scored once with a "tall" intent and once without.
        // With the keyword, the tall photo should clearly outscore a half-body one.
        // Without the keyword, the difference should be near-zero (no penalty for headshots).
        var fullBody = PhotoScore.make(
            qualityScore: 0.70, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.65, aestheticScore: 0.65
        )
        fullBody.subjectHeight = 0.95   // head-to-toe

        var headshot = PhotoScore.make(
            qualityScore: 0.70, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.65, aestheticScore: 0.65
        )
        headshot.subjectHeight = 0.20   // shoulders up

        // Without "tall" keyword: subjectHeightBonus is ×1.0 for both → scores essentially equal.
        let neutralIntent = makeIntent(wantsTall: false)
        let fullBodyNoKeyword = processor.weightedScore(
            fullBody, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: neutralIntent
        )
        let headshotNoKeyword = processor.weightedScore(
            headshot, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: neutralIntent
        )
        XCTAssertEqual(fullBodyNoKeyword, headshotNoKeyword, accuracy: 0.005,
            "Without a tall-subject keyword the headshot vs full-body subjectHeight difference should NOT influence scores")

        // With "tall" keyword: tall photo should win.
        let tallIntent = makeIntent(wantsTall: true)
        let fullBodyWithKeyword = processor.weightedScore(
            fullBody, category: .mugshot, isPromptMode: true, promptText: "make me look tall",
            dynamicRefWeight: 0, hasFaceContent: true, intent: tallIntent
        )
        let headshotWithKeyword = processor.weightedScore(
            headshot, category: .mugshot, isPromptMode: true, promptText: "make me look tall",
            dynamicRefWeight: 0, hasFaceContent: true, intent: tallIntent
        )
        XCTAssertGreaterThan(fullBodyWithKeyword, headshotWithKeyword,
            "When the prompt requests a tall composition, full-body subjectHeight should outscore a headshot")
    }

    // MARK: - 2. Keyword detector

    func test_promptWantsTallSubject_recognisesAllKeywords() {
        let positives = [
            "I want to look tall in these",
            "full body shots only",
            "full-body outfit pics",
            "make me look tall please",
            "statuesque vibes",
            "head to toe shots",
            "leggy aesthetic"
        ]
        for p in positives {
            XCTAssertTrue(processor.promptWantsTallSubject(p),
                "Should recognise tall-subject intent in: '\(p)'")
        }
        let negatives = ["just my best photos", "good lighting", "smiling", ""]
        for p in negatives {
            XCTAssertFalse(processor.promptWantsTallSubject(p),
                "Should NOT detect tall-subject intent in: '\(p)'")
        }
    }

    // MARK: - 3. Vibe bonus

    func test_vibeBonus_higherVibeOutscoresLowerVibe() {
        // Two otherwise-identical photos — only vibeScore differs. The vibey one wins.
        var vibey = PhotoScore.make(
            qualityScore: 0.65, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.60, aestheticScore: 0.60
        )
        vibey.vibeScore = 0.95   // warm + harmonious + bokeh-like

        var clinical = PhotoScore.make(
            qualityScore: 0.65, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.60, aestheticScore: 0.60
        )
        clinical.vibeScore = 0.10   // anti-vibe

        let intent = makeIntent(wantsTall: false)
        let vibeyScore = processor.weightedScore(
            vibey, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        let clinicalScore = processor.weightedScore(
            clinical, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        XCTAssertGreaterThan(vibeyScore, clinicalScore,
            "High vibeScore should outscore low vibeScore, all else equal")
    }

    // MARK: - 4. Trend bonus

    func test_trendBonus_higherTrendOutscoresLowerTrend() {
        var trendy = PhotoScore.make(
            qualityScore: 0.65, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.60, aestheticScore: 0.60
        )
        trendy.trendScore = 0.85   // close to "modern aesthetic" centroid

        var dated = PhotoScore.make(
            qualityScore: 0.65, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.60, aestheticScore: 0.60
        )
        dated.trendScore = 0.15

        let intent = makeIntent(wantsTall: false)
        let trendyScore = processor.weightedScore(
            trendy, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        let datedScore = processor.weightedScore(
            dated, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        XCTAssertGreaterThan(trendyScore, datedScore,
            "High trendScore should outscore low trendScore, all else equal")
    }

    // MARK: - 5. Vibe + trend bonuses are gentle (don't dominate)

    // The new bonuses are intentionally small — a high-quality photo with neutral
    // vibe/trend should still beat a very vibey/trendy mediocre one. This test
    // guards against a future regression where someone cranks the multipliers.
    func test_vibeBonusDoesNotOutweighQuality() {
        var sharpDull = PhotoScore.make(
            qualityScore: 0.90, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.90, categoryScore: 0.80, aestheticScore: 0.80
        )
        sharpDull.vibeScore = 0.10
        sharpDull.trendScore = 0.10

        var blurryVibey = PhotoScore.make(
            qualityScore: 0.45, hasFace: true, isSmiling: true,
            eyeOpenConfidence: 0.90, categoryScore: 0.50, aestheticScore: 0.50
        )
        blurryVibey.vibeScore = 1.0
        blurryVibey.trendScore = 1.0

        let intent = makeIntent(wantsTall: false)
        let sharpScore = processor.weightedScore(
            sharpDull, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        let vibeyScore = processor.weightedScore(
            blurryVibey, category: .mugshot, isPromptMode: false,
            dynamicRefWeight: 0, hasFaceContent: true, intent: intent
        )
        XCTAssertGreaterThan(sharpScore, vibeyScore,
            "A high-quality photo should still beat a low-quality one even with maxed vibe/trend bonuses")
    }

    // MARK: - 6. Reference-driven mode: references dominate more

    // dynamicRefWeight is computed inside processImages. We can't observe it
    // directly from a unit test, but we can verify that *when* it's high (the
    // value reference-driven mode produces — 0.60 at 8+ refs), the reference
    // contribution genuinely dominates the final score relative to base quality.
    // If someone weakens the boost in `dynamicRefWeight` accidentally this
    // ordering flips and the test fails.
    func test_referenceDrivenWeight_makesReferenceContributionDominant() {
        // Two photos: A has a strong reference match (referenceScore = 0.90) but
        // lower base quality. B is technically sharper but less on-style.
        // Standard mode (dynamicRefWeight = 0.25): B should win.
        // Reference-driven mode (dynamicRefWeight = 0.60): A should win.
        let onStyle = PhotoScore.make(
            qualityScore: 0.55, hasFace: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.55, aestheticScore: 0.55,
            referenceScore: 0.90
        )
        let offStyle = PhotoScore.make(
            qualityScore: 0.85, hasFace: true,
            eyeOpenConfidence: 0.85, categoryScore: 0.85, aestheticScore: 0.85,
            referenceScore: 0.20
        )

        let intent = makeIntent(wantsTall: false)

        // Standard weighting — quality wins.
        let onStyleStandard = processor.weightedScore(
            onStyle, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0.25, hasFaceContent: true, intent: intent
        )
        let offStyleStandard = processor.weightedScore(
            offStyle, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0.25, hasFaceContent: true, intent: intent
        )
        XCTAssertGreaterThan(offStyleStandard, onStyleStandard,
            "At standard reference weight (0.25), the technically-better photo should still win")

        // Reference-driven weighting — refs dominate.
        let onStyleDriven = processor.weightedScore(
            onStyle, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0.60, hasFaceContent: true, intent: intent
        )
        let offStyleDriven = processor.weightedScore(
            offStyle, category: .vacation, isPromptMode: false,
            dynamicRefWeight: 0.60, hasFaceContent: true, intent: intent
        )
        XCTAssertGreaterThan(onStyleDriven, offStyleDriven,
            "At reference-driven weight (0.60), the on-style photo should outrank the technically-sharper one")
    }

    // MARK: - Helpers

    private func makeIntent(wantsTall: Bool) -> BatchProcessor.PromptIntent {
        var intent = BatchProcessor.PromptIntent(
            wantsLookingAway: false,
            wantsLookingAtCamera: false,
            wantsEyesClosed: false,
            wantsBlurry: false,
            wantsMotion: false,
            wantsDark: false,
            wantsHighKey: false,
            wantsAwkward: false,
            wantsSerious: false,
            wantsImperfect: false,
            hasFaceContent: true
        )
        intent.wantsTallSubject = wantsTall
        return intent
    }
}
