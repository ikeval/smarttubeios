import XCTest

// MARK: - ShortsPlayerUITests
//
// UI tests for ShortsPlayerView — opened via the Shorts chip on the Home tab.
//
// Requirements:
//   • Network access is required.
//   • The --uitesting-enable-shorts launch argument ensures the Shorts section is
//     present in enabledSections regardless of user settings.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class ShortsPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-enable-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    /// Navigates to the Home tab, scrolls to the Shorts chip, taps it, then
    /// taps the first Short card. Returns when `shorts.indexLabel` is visible.
    private func openFirstShort() throws {
        UITestHelpers.tapTab(named: "Home", in: app)

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "home.chipBar must appear on Home tab")

        let shortsChip = chipBar.buttons["Shorts"]
        guard shortsChip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Shorts chip not found — section may be disabled")
        }
        UITestHelpers.scrollChipIntoView(shortsChip, in: chipBar, app: app)
        shortsChip.tap()

        // Wait for the Shorts section feed to populate.
        let feedPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(feedPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            throw XCTSkip("Shorts feed did not load within 20 s — network unavailable or Shorts empty")
        }

        cards.firstMatch.tap()
        // ShortsPlayerView is visible when shorts.indexLabel appears.
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 15),
                      "shorts.indexLabel must appear after tapping a Short")
    }

    /// Performs a swipe-up gesture on the Shorts player.
    private func swipeUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Performs a swipe-down gesture on the Shorts player.
    private func swipeDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Taps the Shorts player until `shorts.controlsOverlay` becomes visible.
    /// Retries up to 5 times with 1.5 s gaps to account for the UIKit
    /// tap.require(toFail: pan) delay and iOS version timing differences.
    private func showShortsControls() {
        // Search by identifier across all element types to handle iOS 26 VStack rendering changes.
        let pred = NSPredicate(format: "identifier == 'shorts.controlsOverlay'")
        let overlay = app.descendants(matching: .any).matching(pred).firstMatch
        for _ in 0..<5 {
            if overlay.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests

    func testShortsPlayerOpensFromHomeChip() throws {
        try openFirstShort()
        XCTAssertTrue(indexLabel.exists,
                      "shorts.indexLabel should be visible when ShortsPlayerView is open")
    }

    func testIndexLabelShowsStartIndex() throws {
        try openFirstShort()
        // The label format is "1 / N" where N >= 1.
        let labelText = indexLabel.label
        XCTAssertTrue(labelText.hasPrefix("1 /"),
                      "shorts.indexLabel should start with '1 /' when opening the first Short, got: '\(labelText)'")
    }

    func testSwipeUpAdvancesShort() throws {
        try openFirstShort()
        let beforeLabel = indexLabel.label

        swipeUp()
        Thread.sleep(forTimeInterval: 1.5) // animation + load time

        let afterLabel = indexLabel.label
        XCTAssertNotEqual(afterLabel, beforeLabel,
                          "shorts.indexLabel should change after swiping up — expected next Short to load")
        XCTAssertTrue(afterLabel.hasPrefix("2 /"),
                      "After first swipe-up the label should show '2 / N', got: '\(afterLabel)'")
    }

    func testSwipeDownGoesBackToPreviousShort() throws {
        try openFirstShort()
        swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(indexLabel.label.hasPrefix("2 /"),
                      "Should be on index 2 after swiping up")

        swipeDown()
        Thread.sleep(forTimeInterval: 1.5)
        let afterSwipeDown = indexLabel.label
        XCTAssertTrue(afterSwipeDown.hasPrefix("1 /"),
                      "After swiping back down the label should return to '1 / N', got: '\(afterSwipeDown)'")
    }

    func testNoErrorBannerOnShortsOpen() throws {
        try openFirstShort()
        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }

    func testBackButtonDismissesShortsPlayer() throws {
        try openFirstShort()
        showShortsControls()

        // On iOS 26 the back button may not be individually accessible within the
        // controls overlay container even when the overlay is visible. Try via
        // accessibility first; fall back to tapping its known position (top-left).
        let backPred = NSPredicate(format: "identifier == 'shorts.backButton'")
        let backBtn = app.descendants(matching: .any).matching(backPred).firstMatch
        if backBtn.waitForExistence(timeout: 2) {
            backBtn.tap()
        } else {
            // Back button is at the top-left of the controls overlay:
            // HStack with padding(.horizontal, 20).padding(.top, 60)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }

        // After dismissal the Shorts section feed on the Home tab should still be visible.
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should be visible after dismissing the Shorts player")
    }

    func testControlsOverlayAppearsOnTap() throws {
        try openFirstShort()
        showShortsControls()
        let pred = NSPredicate(format: "identifier == 'shorts.controlsOverlay'")
        let overlay = app.descendants(matching: .any).matching(pred).firstMatch
        XCTAssertTrue(overlay.exists,
                      "shorts.controlsOverlay should appear after tapping the Shorts player")
    }
}
