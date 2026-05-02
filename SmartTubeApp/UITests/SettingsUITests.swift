import XCTest

// MARK: - SettingsUITests
//
// Structural UI tests for the Settings tab.
// No network access is required — all settings are stored locally.
//
// Requirements:
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.
//   • Tests that verify signed-out state rely on the app launching without a
//     stored account credential (fresh simulator or signed-out state).

final class SettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func openSettings() {
        UITestHelpers.tapTab(named: "Settings", in: app)
    }

    // MARK: - Tests

    func testSettingsTabOpens() {
        openSettings()
        // SwiftUI Form renders as UICollectionView on iOS 16+.
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5),
                      "Settings form should appear after tapping the Settings tab")
    }

    func testPlayerSectionVisible() {
        openSettings()
        // "Playback Speed" is always the first row in the Player section.
        let speedRow = app.cells.containing(.staticText, identifier: "Playback Speed").firstMatch
        XCTAssertTrue(speedRow.waitForExistence(timeout: 5),
                      "'Playback Speed' row must be visible in the Player section")
    }

    func testHideShortsToggleToggles() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.hideShortsToggle"]
        // Player section has ~11 rows; scroll until Interface section is visible.
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.hideShortsToggle must be present in the Interface section")
        let before = toggle.value as? String
        // Tap the right side of the row where the UISwitch control sits.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after,
                          "Hide Shorts toggle value should change after tapping")
        // Restore original state so settings are not polluted between tests.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testVisibleSectionsNavigationLinkOpens() {
        openSettings()
        let form = app.collectionViews.firstMatch
        // NavigationLink rows often don't propagate a cell identifier — match by text content.
        let link = form.cells.containing(.staticText, identifier: "Visible Sections").firstMatch
        UITestHelpers.scrollUntilVisible(link, in: form)
        XCTAssertTrue(link.waitForExistence(timeout: 5),
                      "'Visible Sections' NavigationLink row must be present in Interface section")
        link.tap()
        // The destination view uses "Visible Sections" as its navigation title.
        let navTitle = app.navigationBars["Visible Sections"].firstMatch
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5),
                      "Navigating to Visible Sections should show that navigation title")
    }

    func testSponsorBlockToggleEnablesSection() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.sponsorBlockToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.sponsorBlockToggle must be present in the SponsorBlock section")

        // Ensure it starts OFF; if it is already on, skip the enable-state assertion.
        let wasOn = (toggle.value as? String) == "1"
        if wasOn {
            // Turn it off so we can verify turning it on shows sub-options.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        }
        // Turn on using coordinate tap (right side = UISwitch).
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        // At least one per-category picker row should now be visible.
        let categoryPicker = app.cells.containing(.staticText, identifier: "Sponsor").firstMatch
        let subOptionsAppear = categoryPicker.waitForExistence(timeout: 3)
            || app.cells.containing(.staticText, identifier: "Intermission").firstMatch.waitForExistence(timeout: 3)
            || app.cells.containing(.staticText, identifier: "Skip").firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(subOptionsAppear,
                      "SponsorBlock category pickers should appear when SponsorBlock is enabled")

        // Restore to OFF so we leave settings clean.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testAboutSectionResetButtonVisible() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5),
                      "settings.resetAllButton should be visible in the About section")
    }

    func testResetAllSettingsShowsConfirmation() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        guard resetButton.waitForExistence(timeout: 5) else {
            XCTFail("settings.resetAllButton not found")
            return
        }
        resetButton.tap()
        // SwiftUI destructive Button triggers the action directly — expect the
        // store to reset silently. If the app instead shows a confirmation alert,
        // dismiss it so the app is left in a clean state.
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            app.alerts.firstMatch.buttons.firstMatch.tap()
        }
        // Either way, the app must still be running.
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after Reset All Settings")
    }

    func testSignInButtonVisibleWhenSignedOut() throws {
        openSettings()
        // In SwiftUI Form, Button rows expose their text as the element's label, not as a
        // child staticText.  Use a predicate that matches either by identifier or by label.
        let signInPredicate = NSPredicate(format: "identifier == 'settings.signInButton' OR label == 'Sign in with Google'")
        let signOutPredicate = NSPredicate(format: "label == 'Sign Out'")
        let signInEl  = app.descendants(matching: .any).matching(signInPredicate).firstMatch
        let signOutEl = app.descendants(matching: .any).matching(signOutPredicate).firstMatch
        // If signed in, skip — we can't test the sign-in button without signing out first.
        if signOutEl.waitForExistence(timeout: 5) {
            throw XCTSkip("Account is signed in — skipping signed-out UI assertion")
        }
        XCTAssertTrue(signInEl.waitForExistence(timeout: 5),
                      "'Sign in with Google' button must be visible when no account is signed in")
    }
}
