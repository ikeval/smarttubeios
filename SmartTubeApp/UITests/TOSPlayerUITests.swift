#if os(macOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of testTOSPlayerAutoSkipsSponsorSegment, load
// .github/skills/ui-tests-with-logs/SKILL.md and inspect the extracted device log.
// Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "No video cards found" / "No non-short video card found" — home feed network
//     unavailable in the simulator. Device log should show NO "[SponsorBlock] UI-TEST
//     INJECT" line (the player was never opened).
//   - "onPlayerReady never fired" — IFrame embed failed to load (network/YouTube
//     availability), unrelated to the SponsorBlock code path under test. Device log
//     should show "[ytCallback] ❌ player error" or no "ready" notice.
//
// BUG skip (must fix before closing):
//   - The "auto-skip did not trigger" XCTAssertEqual failure path — that's a hard
//     failure, not a skip, but treat it identically: investigate before closing.
//   - Any skip reached AFTER "[TOS-sponsorskip] ✓ ready" prints in the test's stdout —
//     by that point the synthetic segment was injected and the only remaining work is
//     the auto-skip path itself, so a skip there means that path broke.
//
// Log events to verify (grep for "[SponsorBlock]"):
//   ✓ "[SponsorBlock] UI-TEST INJECT — bypassing cache/network, applied 1 synthetic
//      segment(s): sponsor[2.0–6.0s]"          — injection seam fired with the right spec
//   ✓ "[SponsorBlock] skip TRIGGER category=sponsor action=skip segment=[2.0s–6.0s]
//      ... before=Xs target=6.00s"             — trigger logged; "before" should read ≈2s
//   ✓ "[SponsorBlock] skip LANDED category=sponsor before=Xs after=Ys skipped≈Zs
//      (target was 6.00s, Δtarget=...)"        — landing confirmed; "after" should read
//                                                 ≈6s and skipped≈ ≈ (after − before) ≈ 4s
//
// RED FLAGS in device log:
//   - ZERO "[SponsorBlock]" lines at all → fetchSponsorSegments returned at its first
//     guard (sponsorBlockEnabled / activeSponsorCategories). Most likely cause: settings
//     persisted to UserDefaults from a PRIOR launch — e.g. the smoke test above runs
//     first with --uitesting-disable-sponsorblock, which SAVES sponsorBlockEnabled=false
//     (see SettingsStore.save()/init()). This bit the very first run of this test —
//     confirm "--uitesting-reset-settings" is still present in this test's launchArguments
//     (it restores AppSettings() defaults before the injection arg is read) before
//     looking anywhere else.
//   - "[SponsorBlock] skip TIMEOUT" → seek fired but currentTime never caught up —
//     investigate seekTo()/the JS bridge, not the logging itself
//   - A second "[SponsorBlock] skip TRIGGER category=sponsor" for the SAME [2.0–6.0s]
//     segment → activeSkipEnd re-entry guard regressed
//   - "skip TRIGGER" present with no matching "skip LANDED"/"skip TIMEOUT" before the
//     log ends → logSkipLanding wiring in the "tick" handler is broken
//   - "[SponsorBlock] toast SHOW" for category=sponsor → settings.sponsorAction
//     defaulted to showToast instead of skip (defaults changed or didn't apply)

// MARK: - TOSPlayerUITests
//
// Smoke test for the macOS IFrame (TOS-compliant) player.
//
// What it verifies:
//   1. Tapping the first non-short video card opens the TOS player (close button visible).
//   2. The IFrame player starts playing within 30 s (Darwin notification fires + AX state = "playing").
//   3. No crash / close-button disappearance during 5 s of playback.
//   4. Tapping the close button dismisses the player (close button disappears).
//
// Preconditions:
//   - useTOSPlayerOnMac defaults to true on macOS (AppSettings.swift).
//   - The test passes --uitesting-disable-sponsorblock to avoid SponsorBlock skips
//     interfering with the simple "is it playing?" assertion.
//
// Lifecycle note: each test launches its OWN XCUIApplication instance exactly once
// via launchApp(extraArguments:) — mirroring HideShortsHomeUITests' launch(hideShorts:)
// (same minimal shape: fresh XCUIApplication, ["--uitesting", ...extra], app.launch(),
// nothing else). There is NO app launch in setUpWithError. This is deliberate: an
// earlier version of testTOSPlayerAutoSkipsSponsorSegment launched once in setUp and
// then did app.terminate() + a second XCUIApplication().launch() mid-test, which
// triggered a DETERMINISTIC auth-state race — the second back-to-back launch
// consistently hung after "Multilogin HTTP 403 INVALID_TOKENS" and never reached
// [Browse]/[Home]/[InnerTube] (reproduced identically twice). A single fresh launch
// per test does not hit this race. Do not reintroduce a mid-test terminate+relaunch.
//
// IMPORTANT — do NOT add saved-application-state deletion or
// "-ApplePersistenceIgnoreState YES" to launchApp. An earlier revision did both
// (to "always open a fresh window"), and that combination, ONLY when paired with
// "--uitesting-reset-settings + at least one more --uitesting-* argument", caused a
// ~100% reproducible hang during auth/home-feed bootstrap — the app got stuck right
// after "Multilogin HTTP 403 INVALID_TOKENS" and never logged [Browse]/[InnerTube]
// setAuthToken/[Home], so "No video cards found" fired at the 41s mark and the test
// SKIPPED. Proven via 11 controlled diagnostics: neither flag content, ordering, nor
// SettingsStore-recognition explained it — swapping in HideShortsHomeUITests' EXACT
// passing args (--uitesting-reset-settings --uitesting-hide-shorts) through the
// persistence-wiping launchApp reproduced the identical hang, while the same args
// through HideShortsHomeUITests' minimal launch() pass reliably. The wipe machinery
// is unnecessary anyway — XCUIApplication already opens a fresh window per launch in
// this single-launch-per-test architecture (confirmed: smoke test passes without it).

final class TOSPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Lifecycle helpers

    /// Launches a fresh `XCUIApplication` with `--uitesting` plus the given extra
    /// arguments. ONE launch per test — see the class-level comment above for why a
    /// mid-test terminate+relaunch is unsafe (deterministic auth-state race between
    /// back-to-back launches).
    private func launchApp(extraArguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"] + extraArguments
        app.launch()
    }

    // MARK: - Test

    func testTOSPlayerPlaysFirstHomeVideo() throws {
        launchApp(extraArguments: ["--uitesting-disable-sponsorblock"])

        // ── 1. Wait for the home feed ─────────────────────────────────────────
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: 30) == .completed else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }

        // Find first non-short card.
        guard let card = firstNonShortCard(from: cards, maxCheck: 20) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let cardID = card.identifier  // "video.card.<videoId>"
        print("[TOS] clicking card: \(cardID)")

        // ── 2. Register Darwin expectations BEFORE clicking ───────────────────
        // CRITICAL: The navigation often completes (and notifies) during the 1s
        // animation that precedes the close button appearing. Expectations must
        // be created BEFORE the click so they capture notifications that fire
        // before the close button is visible.
        let loadStartNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.loadstarted")
        let navNote        = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.navfinished")
        let bridgeNote     = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.bridge")
        let readyNote      = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.ready")
        let tickStartNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.tickstarted")
        let playingNote    = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.playing")
        // State-transition diagnostics (via tick handler): observe which states are hit
        let stateBuffNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.3")
        let stateCuedNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.5")
        let statePauseNote = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.2")
        let stateEndedNote = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.0")

        // ── 3. Tap the card — the TOS player should open ──────────────────────
        if !card.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 100)
            Thread.sleep(forTimeInterval: 0.5)
        }
        card.click()

        // ── 4. Wait for the close button (player appeared) ───────────────────
        let closeBtn = app.buttons["tosPlayer.closeButton"].firstMatch
        XCTAssertTrue(
            closeBtn.waitForExistence(timeout: 15),
            "tosPlayer.closeButton did not appear — TOS player was not opened (check useTOSPlayerOnMac=true)"
        )
        print("[TOS] ✓ player opened — closeButton visible")

        // ── 5. Collect diagnostic notification results ────────────────────────
        // Stage 0a: Was loadHTMLString even called?
        let loadResult = XCTWaiter().wait(for: [loadStartNote], timeout: 1)
        print("[TOS] loadHTMLString called: \(loadResult == .completed ? "✓ YES" : "✗ NO (loadHTML never called)")")

        // Stage 0b: Nav finished — does WKNavigationDelegate.didFinish fire?
        let navResult = XCTWaiter().wait(for: [navNote], timeout: 5)
        if navResult == .completed {
            print("[TOS] ✓ HTML navigation finished (WKNavigationDelegate.didFinish fired)")
        } else {
            print("[TOS] ✗ HTML navigation did NOT finish — didFinish not called within 6s of click")
        }

        // Stage 1: Bridge check — does JS<->Swift messaging work at all?
        let bridgeTimeout: Double = navResult == .completed ? 3 : 0
        let bridgeResult = navResult == .completed
            ? XCTWaiter().wait(for: [bridgeNote], timeout: bridgeTimeout)
            : .timedOut
        if bridgeResult == .completed {
            print("[TOS] ✓ JS<->Swift bridge confirmed working")
        } else {
            print("[TOS] ✗ JS<->Swift bridge NOT working — window.webkit.messageHandlers unavailable")
        }

        // Stage 2: onPlayerReady — did the iframe_api script load?
        let readyTimeout: Double = bridgeResult == .completed ? 30 : 0
        let readyResult = bridgeResult == .completed
            ? XCTWaiter().wait(for: [readyNote], timeout: readyTimeout)
            : .timedOut
        if readyResult == .completed {
            print("[TOS] ✓ onPlayerReady fired — iframe_api loaded")
        } else if bridgeResult == .completed {
            print("[TOS] ✗ onPlayerReady did NOT fire within 30s — iframe_api script may have failed to load")
        }

        // Stage 2.5: Tick poll — is startPolling() running?
        let tickResult = readyResult == .completed
            ? XCTWaiter().wait(for: [tickStartNote], timeout: 3)
            : .timedOut
        if tickResult == .completed {
            print("[TOS] ✓ tick poll received — startPolling() is running")
        } else if readyResult == .completed {
            print("[TOS] ✗ no tick received within 3s of ready — startPolling() may not be called")
        }

        // Stage 3: playing state
        let playingTimeout: Double = readyResult == .completed ? 15 : 0
        let playResult = readyResult == .completed
            ? XCTWaiter().wait(for: [playingNote], timeout: playingTimeout)
            : .timedOut

        // Also poll the AX state label as a secondary check.
        let stateLabel = app.descendants(matching: .any).matching(identifier: "tosPlayer.stateLabel").firstMatch
        let isPlaying: Bool
        if playResult == .completed {
            isPlaying = true
            print("[TOS] ✓ Darwin notification received — player is playing")
        } else {
            // Darwin notification timed out — check AX state (label or value).
            // On macOS 26, SwiftUI Text exposes text content via AXValue (not AXTitle).
            let labelValue = stateLabel.exists ? stateLabel.label : "(not found)"
            let valueStr   = stateLabel.exists ? (stateLabel.value as? String ?? "") : ""
            let stateStr   = labelValue.isEmpty ? valueStr : labelValue
            isPlaying = stateStr == "playing" || stateStr == "buffering"
            // Report which states were observed (helps diagnose autoplay blocking)
            let seenBuffering = XCTWaiter().wait(for: [stateBuffNote],  timeout: 0) == .completed
            let seenCued      = XCTWaiter().wait(for: [stateCuedNote],  timeout: 0) == .completed
            let seenPaused    = XCTWaiter().wait(for: [statePauseNote], timeout: 0) == .completed
            let seenEnded     = XCTWaiter().wait(for: [stateEndedNote], timeout: 0) == .completed
            let statesSeen    = [seenBuffering ? "buffering(3)" : nil,
                                 seenCued      ? "cued(5)"      : nil,
                                 seenPaused    ? "paused(2)"    : nil,
                                 seenEnded     ? "ended(0)"     : nil]
                .compactMap { $0 }.joined(separator: ",")
            print("[TOS] playing notification timed out — stateLabel='\(stateStr)' states=[\(statesSeen.isEmpty ? "none — stuck at -1/unstarted" : statesSeen)]")
        }

        XCTAssertTrue(
            isPlaying,
            "TOS player did not reach 'playing' state within 30 s — check network, baseURL whitelist, and autoplay config"
        )

        // ── 6. Let it play for 5 s and verify no crash ───────────────────────
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(
            closeBtn.exists,
            "tosPlayer.closeButton disappeared during playback — possible crash or view re-render"
        )
        print("[TOS] ✓ 5 s of playback — no crash")

        // ── 7. Close the player ───────────────────────────────────────────────
        closeBtn.click()

        let closedPredicate = NSPredicate(format: "exists == false")
        let closedExpect = XCTNSPredicateExpectation(predicate: closedPredicate, object: closeBtn)
        let closedResult = XCTWaiter().wait(for: [closedExpect], timeout: 5)
        XCTAssertEqual(
            closedResult, .completed,
            "tosPlayer.closeButton still visible after close tap — player did not dismiss"
        )
        print("[TOS] ✓ player dismissed — test complete")
    }

    // MARK: - SponsorBlock auto-skip test

    /// Exercises the TOS player's SponsorBlock auto-skip path end-to-end and verifies
    /// (via the `com.void.smarttube.tosplayer.sponsorskip` Darwin notification — see
    /// `TOSPlayerViewModel.checkSponsorSkip`) that a skip actually fires.
    ///
    /// Why this needs its own launch arguments, distinct from the smoke test's:
    ///   - The smoke test above runs with `--uitesting-disable-sponsorblock` specifically
    ///     to AVOID exercising this path (its assertion is just "does it play"). This test
    ///     is the dedicated SponsorBlock exercise, so it needs the opposite — SponsorBlock
    ///     left ON — plus a synthetic segment via `--uitesting-inject-sponsor-segments=`
    ///     (see `TOSPlayerViewModel.fetchSponsorSegments`) so the skip fires deterministically
    ///     ~2s into playback no matter which random home-feed video loads or whether the
    ///     live SponsorBlock API has real data for it.
    ///   - "sponsor" is the injected category because `AppSettings`'s default action for
    ///     it is `.skip` (see `AppSettings.init`) — no extra settings juggling required.
    ///   - `--uitesting-reset-settings` is REQUIRED here: settings persist to UserDefaults
    ///     across launches (see SettingsStore.save()/init()), and XCTest may run the smoke
    ///     test (which sets+saves sponsorBlockEnabled=false via --uitesting-disable-sponsorblock)
    ///     before this one in the same suite run. Without resetting, this test would inherit
    ///     that persisted false, fail `fetchSponsorSegments`'s very first guard, and never
    ///     even reach the injection seam (silently zero "[SponsorBlock]" log lines — this
    ///     bit the very first run of this test). --uitesting-reset-settings restores
    ///     AppSettings() defaults — sponsorBlockEnabled=true, "sponsor" → .skip — before
    ///     --uitesting-inject-sponsor-segments is read.
    func testTOSPlayerAutoSkipsSponsorSegment() throws {
        launchApp(extraArguments: [
            "--uitesting-reset-settings",
            "--uitesting-inject-sponsor-segments=2-6:sponsor",
        ])

        // ── 1. Wait for the home feed, pick the first non-short video ────────────
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: 30) == .completed else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards, maxCheck: 20) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }
        print("[TOS-sponsorskip] clicking card: \(card.identifier)")

        // ── 2. Register Darwin expectations BEFORE clicking (see smoke test above ─
        //      for why: notifications can fire during the open animation).
        let readyNote   = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.ready")
        let playingNote = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.playing")
        let skipNote    = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.sponsorskip")

        // ── 3. Open the player ────────────────────────────────────────────────────
        if !card.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 100)
            Thread.sleep(forTimeInterval: 0.5)
        }
        card.click()

        let closeBtn = app.buttons["tosPlayer.closeButton"].firstMatch
        XCTAssertTrue(
            closeBtn.waitForExistence(timeout: 15),
            "tosPlayer.closeButton did not appear — TOS player was not opened"
        )
        print("[TOS-sponsorskip] ✓ player opened")

        // ── 4. "ready" is when fetchSponsorSegments() runs and the injection seam ─
        //      applies the synthetic segment (see TOSPlayerViewModel "ready" handler).
        guard XCTWaiter().wait(for: [readyNote], timeout: 30) == .completed else {
            throw XCTSkip("onPlayerReady never fired — iframe_api may have failed to load (network)")
        }
        print("[TOS-sponsorskip] ✓ ready — synthetic segment [2–6]s should now be applied")

        _ = XCTWaiter().wait(for: [playingNote], timeout: 15)

        // ── 5. Wait for the auto-skip ─────────────────────────────────────────────
        // The injected segment starts at currentTime=2s; playback starts at 0, so
        // ~2s of real playback (plus startup/buffering latency) should trigger it.
        // 25s comfortably covers slow CI startup without masking a real "never
        // skips" regression (which would otherwise hang until this test's own
        // timeout with no informative failure message).
        let skipResult = XCTWaiter().wait(for: [skipNote], timeout: 25)
        XCTAssertEqual(
            skipResult, .completed,
            "com.void.smarttube.tosplayer.sponsorskip never fired — TOS player did not " +
            "auto-skip the injected sponsor segment [2–6]s. Check the device log for " +
            "'[SponsorBlock] UI-TEST INJECT' (segment applied?) and 'skip TRIGGER' (guard " +
            "conditions in checkSponsorSkip — sponsorBlockEnabled / activeSkipEnd / sponsorAction)."
        )
        print("[TOS-sponsorskip] ✓ auto-skip notification received — checkSponsorSkip fired seekTo()")

        // ── 6. Player survives the skip — no crash / re-render ───────────────────
        // Sleep long enough for `logSkipLanding`'s "after" log to actually fire and
        // get captured in the device log before teardown. It polls on each ~250ms
        // "tick" and gives up after 16 ticks (~4s) with a TIMEOUT log if the seek
        // never lands (see TOSPlayerViewModel.logSkipLanding). A 2s sleep here
        // (the previous value) ends BEFORE that worst-case window closes, so the
        // "skip LANDED"/"skip TIMEOUT" half of the before/after pair never gets
        // emitted while the app is still alive — leaving only "skip TRIGGER" in the
        // captured log (confirmed: a real run with sleep=2 showed TRIGGER but no
        // LANDED/TIMEOUT). 6s comfortably clears the ~4s worst case with margin for
        // logging + capture-buffer flush latency.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(
            closeBtn.exists,
            "tosPlayer.closeButton disappeared after the auto-skip — possible crash or view re-render"
        )
        print("[TOS-sponsorskip] ✓ player survived the skip — no crash")

        // ── 7. Close the player ───────────────────────────────────────────────────
        closeBtn.click()
        let closedExpect = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: closeBtn
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [closedExpect], timeout: 5), .completed,
            "tosPlayer.closeButton still visible after close tap — player did not dismiss"
        )
        print("[TOS-sponsorskip] ✓ player dismissed — test complete (inspect device log for skip TRIGGER/LANDED before/after times)")
    }

    // MARK: - Helpers

    private func firstNonShortCard(from query: XCUIElementQuery, maxCheck: Int) -> XCUIElement? {
        let count = min(query.count, maxCheck)
        for i in 0..<count {
            let el = query.element(boundBy: i)
            // AX value "short" is set on short cards by VideoCardView.
            if el.value as? String != "short" { return el }
        }
        return nil
    }
}

#endif // os(macOS)
