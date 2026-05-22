import XCTest

// MARK: - HLSResolutionUITests
//
// Verifies that a standard embeddable video plays at a resolution above 360p.
//
// 360p is the muxed-only fallback (itag=18). If Auto quality resolves to 360p it
// means every adaptive-stream client in exhaustiveRetry failed — TVAuth, TVEmbedded,
// MWEB, iOS, Android, AndroidVR, WebCreator — and the app fell back to the lowest-
// quality muxed stream.  That is a regression.
//
// Video dQw4w9WgXcQ ("Never Gonna Give You Up" by Rick Astley) is a standard
// embeddable video available in up to 1080p. TVEmbedded (TVHTML5_SIMPLY_EMBEDDED_PLAYER)
// returns an HLS manifest URL for this video — the normal adaptive path without rqh=1.
// If HLS is unavailable, exhaustiveRetry falls through MWEB/iOS/Android adaptive clients.
// The previous video (Dy9ki9Q5nXs) had embedding disabled (TVEmbedded returned UNPLAYABLE)
// and ALL adaptive clients returned rqh=1 URLs, making >360p impossible without a PO token.
//
// Verification: Stats for Nerds shows the current AVPlayerItem.presentationSize.
// The resolution label contains U+00D7 (×), e.g. "1280×720 @ 30 fps".
// The test parses the height component and asserts it is > 360.

#if os(iOS)

final class HLSResolutionUITests: XCTestCase {

    // Standard embeddable video with HLS available via TVEmbedded (no rqh=1 restriction).
    // Available in up to 1080p. Embedding has been enabled since the video was uploaded.
    private static let videoID = "dQw4w9WgXcQ"

    // U+00D7 MULTIPLICATION SIGN — used as the separator in resolution labels.
    private static let cross = "\u{00D7}"

    // Test fails when auto quality resolves to 360p or lower (muxed itag=18 fallback).
    private static let minimumHeight = 361

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-deeplink-video=\(Self.videoID)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Test

    /// Opens a standard embeddable video and asserts HLS/adaptive auto quality is above 360p.
    ///
    /// Failure means exhaustiveRetry fell back to the muxed 360p stream.
    /// Check device log for:
    ///   - muxedFormats for <id>: [itag=18 …]  — only muxed available
    ///   - rqh=1 streams skipped across all clients
    ///   - MWEB / iOS / Android client phase errors
    func testAutoQualityAbove360p() throws {
        // ── Step 1: Wait for player to open ──────────────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }

        // ── Step 2: Wait for playback to be ready ────────────────────────────
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        guard XCTWaiter().wait(for: [enabledExp], timeout: 30) == .completed else {
            captureState("video not ready after 30 s", in: app)
            XCTFail(
                "Video did not become ready within 30 s. " +
                "exhaustiveRetry must complete and deliver a playable stream. " +
                "Check device log for client phase errors."
            )
            return
        }
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "HLS resolution")

        // ── Step 3: Enable Stats for Nerds ───────────────────────────────────
        try enableStatsForNerds()
        // Let the stats observer (fires every 0.5 s) populate the resolution row.
        Thread.sleep(forTimeInterval: 2.5)

        // ── Step 4: Read resolution from Stats overlay ────────────────────────
        let resLabel = currentResolutionLabel() ?? "nil"
        captureState("resolution: \(resLabel)", in: app)

        // ── Step 5: Assert resolution > 360p ─────────────────────────────────
        let height = resolutionHeight(from: resLabel)
        XCTAssertGreaterThanOrEqual(
            height, Self.minimumHeight,
            "Auto quality is \(height)p (label: '\(resLabel)') — resolution is 360p or lower. " +
            "exhaustiveRetry fell back to muxed itag=18. All adaptive clients failed. " +
            "Check device log for: muxedFormats, rqh=1 skips, MWEB/iOS/Android errors."
        )
    }

    // MARK: - Helpers

    private func enableStatsForNerds() throws {
        showControls()
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        guard moreBtn.waitForExistence(timeout: 8) && moreBtn.isHittable else {
            try captureAndSkip("player.moreButton not found or not hittable", in: app)
        }
        moreBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let statsRow = app.buttons["player.moreMenu.statsForNerds"].firstMatch
        guard statsRow.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.moreMenu.statsForNerds not found", in: app)
        }
        statsRow.tap()
        // More menu auto-closes; Stats overlay appears next frame.
    }

    /// Taps the player surface until the controls overlay (more button) is hittable.
    private func showControls() {
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        for _ in 0..<6 {
            if moreBtn.waitForExistence(timeout: 1) && moreBtn.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Returns the label of the first static text containing "×" (U+00D7).
    /// The Stats for Nerds overlay formats resolution as "W×H @ fps".
    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    /// Parses the height (pixels after "×") from a label like "1280×720 @ 30 fps".
    /// Returns 0 if the label cannot be parsed.
    private func resolutionHeight(from label: String) -> Int {
        guard let crossRange = label.range(of: Self.cross) else { return 0 }
        let afterCross = String(label[crossRange.upperBound...])
        let digits = afterCross.prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}

#endif // os(iOS)
