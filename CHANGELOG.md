# Changelog

All notable changes to SmartTube are documented here.

---

## [Unreleased] – 2026-05-12

### Fixed
- Audio-only mode silently stalling on playback start — `tryLoadAudioURL` now sets up an `itemObserverTask` before replacing the current `AVPlayerItem`, so `.failed` status is caught and falls back to HLS instead of hanging
- Mini player X button sometimes restoring fullscreen — `RootView` binding setter now guards `presentation == .fullScreen` before calling `minimize()`, preventing a stale async `onDismiss` from overriding `stop()`
- Audio track selection not working after fallback recovery — `retryWithFallbackPlayer`, `retryWithAdaptiveComposition`, and `retryWith403Recovery` now call `loadAudioTracks(from:)` in their `.readyToPlay` observers, keeping `audioSelectionGroup` in sync with the active player item
- More menu overflowing and unusable in landscape mode — `moreMenuOverlay` now uses a compact max-height (320 pt) in `verticalSizeClass == .compact` and adds horizontal safe-area + landscape padding so the menu stays within the live area and is scrollable

---

## [2.4] – 2026-05-10

### Fixed
- Audio cutting out when manually changing video resolution
- Audio quality improved — spectral pitch algorithm matches official YouTube app
- Duplicate video cards causing blank cells in Home and Subscriptions feeds
- tvOS centre-zone double-tap and d-pad focus issues in player UI tests

---

## [2.3] – 2026-05-10

### Added
- Shorts section on home screen with portrait thumbnails
- Per-device YouTube recommendations setting (toggle in Settings)

---

## [2.2] – 2026-05-06/07

### Added
- **Local Subscription Management** — follow/unfollow channels without a Google account; feeds backed by `LocalSubscriptionStore` and `LocalSubscriptionFeedService`
- `YouTubeRSSParser` — XML-based RSS parser for YouTube channel feeds, with background refresh and `LocalSubscriptionFeedCache`
- **Picture-in-Picture** (iOS) — PiP session management in `PlaybackViewModel`; toggle in Settings
- "Landscape Always Play" setting — auto-rotate to landscape when a video starts on iPhone
- `YouTubeRSSParserTests`, `LocalSubscriptionStoreTests`, `LocalSubscriptionFeedServiceTests` unit tests

### Fixed
- Shorts player section feed sometimes not visible when test starts — added explicit wait for section feed before asserting

---

## [2.1] – 2026-05-04/05

### Added
- **Landscape playback for iOS** — `OrientationManager` + `LandscapeAwareHostingController` replace SwiftUI's portrait-locked hosting controller so UIKit accepts `requestGeometryUpdate(.landscape)` while the player is on screen
- **tvOS PlayerView** (`PlayerView+tvOS`) — full d-pad navigation with `TVPlayerControl` focus model; Siri Remote play/pause, seek, menu/back handling
- **Now Playing** — lock screen and Dynamic Island metadata, artwork, and transport controls via `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`
- **Playback quality selection** — manual format override with `PlaybackViewModel+Quality`; HLS variant URL fetching; toast confirmation via `ToastModifier`
- **Previous/next video navigation** — history stack in `PlaybackViewModel+Navigation`; `playNext()` / `playPrevious()`
- **Caption track selection** — VTT fetch and live cue overlay in `PlaybackViewModel+Captions`
- **Sleep timer** — countdown task in `PlaybackViewModel+SleepTimer`
- **Like/Dislike actions** — `PlaybackViewModel+LikeDislike`
- **Stats for Nerds** overlay — `PlaybackViewModel+StatsForNerds`
- `PlayerView+Overlays` and `PlayerView+PickerOverlays` — player UI extracted into focused extension files
- `ToastModifier` — self-dismissing pill message (auto-clears binding after 2 s)
- `ScrollOffsetPreserver` — saves and restores LibraryView scroll position across tab switches
- Updated app icon (dark variant added)

### Changed
- `PlaybackViewModel` split into 14 focused extensions (Auth, AudioTracks, Captions, Controls, ControlsVisibility, Fallback, LikeDislike, Loading, Navigation, NowPlaying, Observers, Quality, SleepTimer, SponsorBlock, StatsForNerds)
- Enhanced error handling and retry logic for failed stream requests
- BrowseViewModel recommended-video fetch deduplicates results
- Improved focus management for picker overlays on tvOS

---

## [2.0] – 2026-05-03/04

### Added
- **Localisation** — `Localizable.xcstrings` string catalog covering the full app
- `InnerTubeAPIProtocol` — protocol abstraction over `InnerTubeAPI` enabling mock injection in tests
- `ViewModelLogger` — structured per-category logging routed to Crashlytics
- Sign-in UI: one-tap "Open Activation Page" button (opens pre-filled URL); "Or scan from another device" QR divider section
- Sign-in progress guard in `AuthService` — prevents concurrent device-code flows
- Comprehensive unit tests: `WebVTTParserTests`, `VideoStateStoreTests`, `ViewModelTests`, `VideoPreloadCacheTTLTests`, `SearchFilterUITests`, `YouTubeLinkHandlerTests`
- UI test suites: Channel, Library (History / Playlists / Subscriptions), Player controls, Recommended chip pagination, Search, Settings, Shorts, Audio track selection
- GitHub issue templates (bug report, feature request)

### Changed
- Updated Privacy Policy
- Various internal refactors for readability and maintainability

---

## [1.9] – 2026-05-02

### Added
- Home feed staleness check — `HomeViewModel.refreshIfStale(threshold:)` reloads shelves when content is older than 15 minutes
- `InnerTubeAPI`: authenticated playback tracking URLs (`fetchAuthenticatedTrackingURLs`), TV-client endpoint (`postTV`), section-date and relative-date parsing
- Home feed fallback to popular videos when watch history is empty

### Changed
- HomeView replaced shelf rows with `VideoGridSection` grid layout
- `VideoCardView` layout and thumbnail improvements

---

## [1.8] – 2026-05-01

### Added
- Android-client HLS fallback in `PlaybackViewModel` — retries with Android credentials when the iOS HLS manifest returns a 404 due to IP-binding; last attempted URL stamped into Crashlytics non-fatal reports
- `VideoPlaybackRegressionUITests` — UI test coverage for core playback flows

### Changed
- `VideoPreloadCache` keeps its `InnerTubeAPI` access-token in sync with the signed-in session

---

## [1.7] – 2026-04-30

### Added
- `VideoPreloadCache` — background prefetch and cache of video stream data keyed by video ID
- `WatchtimeTracker` — reports playback position metrics to YouTube's watchtime endpoint
- `InnerTubeAPIKey` SwiftUI environment key — all views receive `InnerTubeAPI` via `@Environment(\.innerTubeAPI)` instead of constructor injection

### Changed
- Updated InnerTube client version strings

---

## [1.6] – 2026-04-28/29 — Initial Open Source Release

### Added
- Initial open source release of SmartTube for iPhone, iPad, macOS, and Apple TV
- **Audio track selection** — loads alternate HLS renditions (dubbed/translated tracks) from the manifest; auto-selects by device locale; persisted in `AppSettings`
- tvOS d-pad navigation in the player — custom `TVPlayerControl` enum; directional seek, play/pause, and back without SwiftUI focus engine
- tvOS Settings: Ko-fi and GitHub QR code sheets
- Firebase dSYM copy script for crash symbolication
- `CrashlyticsLogger` integration

### Changed
- `AuthService`: concurrent sign-in guard; automatic sign-out on permanent OAuth failures (`invalid_grant`, `invalid_client`, `unauthorized_client`); device code expiration clamped at server-reported `expiresIn`
- `VideoDownloadService` download-session and background-task code restricted to iOS with `#if os(iOS)` guards
- `PlaybackViewModel`: foreground/background audio session handling (`handleForeground()` / `handleBackground()`)
