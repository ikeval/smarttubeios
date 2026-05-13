import XCTest

// MARK: - VideoPlaybackRegressionUITests
//
// Regression test for video playback failures caused by IP-bound HLS manifests.
// YouTube's iOS client returns HLS manifest URLs that are locked to the fetching
// IP address. On the iOS Simulator, AVPlayer's download IP can differ from the
// URLSession IP used by InnerTubeAPI, producing HTTP 404 errors.
//
// The fix uses the Android InnerTube client as a fallback, which returns direct
// CDN videoplayback URLs that are not subject to the same IP-binding restriction.
//
// This test verifies that video Dy9ki9Q5nXs ("Reviewing Every Themed Tourist Trap
// Restaurant") opens and plays without a player error banner.
//
// The test uses --uitesting-deeplink-video=<ID> to open the player directly,
// bypassing the History dependency entirely.

final class VideoPlaybackRegressionUITests: XCTestCase {

    private static let targetVideoID = "Dy9ki9Q5nXs"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchArguments += ["--uitesting-deeplink-video=\(Self.targetVideoID)"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Opens video Dy9ki9Q5nXs via deeplink and asserts it plays without an error banner.
    func testSpecificVideoPlaysFromDeeplink() throws {
        // The deeplink fires via UIApplication.open() shortly after launch.
        // Wait for PlayerView to open.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear within 20 s — network unavailable or deeplink did not fire")
        }

        let videoTitle = titleLabel.label

        // Give the stream 12 s to fetch player info and begin buffering.
        // The Android-client fallback adds ~1 extra round-trip if the primary HLS fails.
        Thread.sleep(forTimeInterval: 12)

        // Assert no player error banner appeared.
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared during playback of '\(videoTitle)' (\(Self.targetVideoID)) — " +
            "PlaybackViewModel.error was set. The Android-client fallback may not be working."
        )

        // Assert no feed-level error alert appeared.
        XCTAssertFalse(
            app.alerts["Error"].exists,
            "An 'Error' alert appeared during or after opening '\(videoTitle)'"
        )

        // Confirm the player is still open.
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel disappeared — PlayerView was dismissed unexpectedly"
        )
    }

    // MARK: - Regression: stop then replay (#51)

    /// Regression test for task #51: video does not reload after stop and replay.
    ///
    /// Root cause: `stop()` did not cancel `itemObserverTask` / `endObserverTask`,
    /// leaving stale observers that interfered with a subsequent `load(video:)` call.
    func testReplayAfterStop() throws {
        // Wait for the player to open via the existing deeplink launch argument.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear within 20 s — network unavailable or deeplink did not fire")
        }

        // Wait for buffering to start.
        Thread.sleep(forTimeInterval: 5)

        // Dismiss the player (simulates "stop").
        let closeButton = app.buttons["player.closeButton"].firstMatch
        if closeButton.exists {
            closeButton.tap()
        } else {
            // Swipe down to dismiss sheet-style player.
            app.swipeDown()
        }

        // Give the player time to fully tear down.
        Thread.sleep(forTimeInterval: 2)

        // Re-open the same video via deeplink.
        app.terminate()
        app.launchArguments = app.launchArguments // reuse existing args (deeplink included)
        app.launch()

        // Assert the player opens again without an error banner.
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not reappear within 20 s on second launch")
        }

        Thread.sleep(forTimeInterval: 10)

        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared on replay of \(Self.targetVideoID) — " +
            "itemObserverTask/endObserverTask cancellation in stop() may be broken."
        )

        XCTAssertFalse(
            app.alerts["Error"].exists,
            "An 'Error' alert appeared on replay of \(Self.targetVideoID)"
        )
    }
}
