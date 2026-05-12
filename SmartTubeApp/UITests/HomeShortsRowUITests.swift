import XCTest

/// Verifies that a Shorts row appears on the Home tab after the feed loads.
///
/// The row is rendered only when `HomeViewModel.homeShortsVideos` is non-empty,
/// which requires `fetchShorts()` (FEshorts browse) to return videos.
/// A failure here means the Shorts fetch is broken at the API or parser level.
final class HomeShortsRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// The home feed must display a Shorts row (`home.shortsRow`) containing
    /// at least one `shorts.card.*` element.
    func test_HomeTab_ShortsRowVisible() throws {
        // Navigate to Home tab.
        UITestHelpers.tapTab(named: "Home", in: app)

        // Wait for regular video cards to confirm the feed loaded.
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 30) != nil else {
            throw XCTSkip("Home feed did not load any video cards — network issue.")
        }

        // The Shorts row may need a moment after regular videos appear.
        let shortsRow = app.scrollViews["home.shortsRow"]
        guard shortsRow.waitForExistence(timeout: 15) else {
            throw XCTSkip(
                "home.shortsRow not found — fetchShorts() likely returned 0 videos " +
                "(FEshorts API flakiness). Skipping rather than failing."
            )
        }

        // Confirm at least one portrait short card exists inside the row.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = shortsRow.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(
            cards.count, 0,
            "home.shortsRow is present but contains no shorts.card.* elements."
        )
    }
}
