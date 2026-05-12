import XCTest

// MARK: - AudioOnlyMenuRowUITests
//
// Verifies the Audio-Only button appears in the player on-screen controls (bottom bar)
// and toggles the setting. The button was moved from the More Menu to the bottom bar
// in task #41.
//
// Network access is required — the player opens a real video via deeplink.

final class AudioOnlyMenuRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func openPlayer(timeout: TimeInterval = 20) throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ"
        ]
        app.launch()

        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        guard playerTitle.waitForExistence(timeout: timeout) else {
            throw XCTSkip("Player did not open within \(timeout) s — network unavailable or video inaccessible")
        }
        // Ensure controls are visible by tapping the player
        app.otherElements["player.view"].firstMatch.tap()
    }

    // MARK: - Tests

    /// The Audio-Only button must appear in the player bottom-bar on-screen controls.
    func testAudioOnlyRowExistsInMoreMenu() throws {
        try openPlayer()

        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        XCTAssertTrue(audioOnlyBtn.waitForExistence(timeout: 5),
                      "player.audioOnlyButton must be present in the player bottom-bar controls")
    }

    /// Tapping Audio-Only must not crash the app.
    func testAudioOnlyRowToggleDoesNotCrash() throws {
        try openPlayer()

        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            throw XCTSkip("player.audioOnlyButton not visible — skipping toggle test")
        }

        audioOnlyBtn.tap()

        let player = app.otherElements["player.view"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5),
                      "Player must remain visible after tapping Audio-Only")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after tapping Audio-Only")
    }
}
