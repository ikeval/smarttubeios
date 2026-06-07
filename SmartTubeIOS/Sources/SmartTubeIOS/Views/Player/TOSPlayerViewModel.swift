#if os(macOS)
import Foundation
import CoreFoundation
import WebKit
import SmartTubeIOSCore
import os

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - YTPlayerState

/// Maps the numeric state code returned by the YouTube IFrame API.
enum YTPlayerState: Int {
    case unstarted  = -1
    case ended      =  0
    case playing    =  1
    case paused     =  2
    case buffering  =  3
    case cued       =  5
    case unknown    = 999

    init(raw: Int) {
        self = YTPlayerState(rawValue: raw) ?? .unknown
    }
}

// MARK: - TOSPlayerError

enum TOSPlayerError: Equatable {
    /// Video does not allow embedding (IFrame error 101 / 150).
    case embeddingDisabled
    /// Video not found (IFrame error 100).
    case notFound
    /// Generic IFrame player error.
    case iframeError(Int)
    /// WKWebView failed to load the player page.
    case webViewLoadFailed

    var isFatal: Bool {
        switch self {
        case .embeddingDisabled, .notFound, .webViewLoadFailed: return true
        case .iframeError(153): return true  // Video player configuration error
        default: return false
        }
    }
}

// MARK: - TOSPlayerViewModel

/// State owner for the macOS TOS-compliant YouTube embed player.
///
/// Architecture: loads `https://www.youtube.com/embed/{videoId}` directly in WKWebView
/// (not via the IFrame API in our own HTML), then injects `stateDetectionJS` to poll
/// the `<video>` element and relay state via `window.webkit.messageHandlers.ytCallback`.
///
/// All mutation is `@MainActor`. The `WKScriptMessageHandler` bridge dispatches back
/// to main actor via `Task { @MainActor in ... }`.
@MainActor
@Observable
final class TOSPlayerViewModel: NSObject {

    // MARK: - Public state

    var playerState: YTPlayerState = .unstarted
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1.0
    var isReady: Bool = false
    /// Non-nil when the player encounters an error that requires falling back.
    var playerError: TOSPlayerError? = nil

    // MARK: - SponsorBlock

    var sponsorSegments: [SponsorSegment] = []
    /// The segment currently showing a skip toast, if any.
    var currentToastSegment: SponsorSegment? = nil

    // MARK: - Like / Dislike / Sleep Timer
    //
    // Transferred from PlaybackViewModel+LikeDislike.swift / +SleepTimer.swift —
    // see TOSPlayerViewModel+LikeDislike.swift / +SleepTimer.swift for the
    // `like()`/`dislike()`/`setSleepTimer(minutes:)` implementations. Both features
    // are pure API/timer operations with no AVPlayer dependency, so they port
    // verbatim. State lives here (with the rest of the model's @Observable storage);
    // mutation is split out to extension files mirroring the PlaybackViewModel+*
    // pattern — hence `internal` rather than `private(set)`/`private`, the same
    // trade-off PlaybackViewModel makes with `public internal(set)`.

    /// Optimistically updated in like()/dislike(); rolled back on API failure.
    /// Seeded from cached `nextInfo.likeStatus` in `beginWatchtimeTracking()`.
    var likeStatus: LikeStatus = .none
    /// Non-nil while a sleep-timer countdown is active; drives the moreButton's label
    /// and the checkmark in its picker submenu. Mirrors `PlaybackViewModel.sleepTimerMinutes`.
    var sleepTimerMinutes: Int? = nil
    @ObservationIgnored var sleepTimerTask: Task<Void, Never>?

    // MARK: - Dependencies

    private(set) var settings: AppSettings = AppSettings()
    /// Used by `fetchSponsorSegments()` (TOSPlayerViewModel+SponsorBlock.swift).
    let sponsorService = SponsorBlockService()
    /// Used directly by like()/dislike() (TOSPlayerViewModel+LikeDislike.swift —
    /// pure InnerTubeAPI calls, no AVPlayer dependency) and to construct `tracker` below.
    let api: InnerTubeAPI
    /// Drives watch-position checkpointing (VideoStateStore) and watch-history
    /// reporting (InnerTubeAPI) — parity with the standard PlaybackViewModel's
    /// `tracker`. See `beginWatchtimeTracking()`/`saveProgress()`
    /// (TOSPlayerViewModel+WatchHistory.swift) for where this is begun/used.
    let tracker: WatchtimeTracker

    // MARK: - Internal

    let webView: WKWebView
    /// Used by `fetchSponsorSegments()`/`beginWatchtimeTracking()`/`saveProgress()`/
    /// `like()`/`dislike()` — all in extension files, hence `internal` not `private`.
    let videoId: String
    /// Used to respect `settings.sponsorBlockExcludedChannels` — mirrors the
    /// channel-exclusion check in `PlaybackViewModel+Loading`'s SponsorBlock phase.
    /// Read by `fetchSponsorSegments()` in TOSPlayerViewModel+SponsorBlock.swift.
    let channelId: String?
    private let startTime: Double
    /// Guards against re-triggering a skip within the same segment.
    /// Mutated by `checkSponsorSkip(at:)` in TOSPlayerViewModel+SponsorBlock.swift.
    var activeSkipEnd: Double? = nil
    /// Set when an auto-skip seek is fired; cleared once a subsequent "tick" confirms
    /// where playback landed (or times out). `seekTo` is a fire-and-forget JS eval with
    /// no completion callback, so the "after" time can only be observed asynchronously
    /// from the next tick — never synchronously right after calling `seekTo`. See
    /// `PendingSkipLog` / the "tick" handler in `handleScriptMessage` for the landing
    /// check (both in TOSPlayerViewModel+SponsorBlock.swift).
    var pendingSkipLog: PendingSkipLog? = nil
    /// The most recently logged toast segment, so `checkSponsorSkip` logs a "toast SHOW"
    /// notice only on the transition into a new segment — not on every tick while the
    /// toast remains visible (which would spam the log at ~4 lines/second).
    var lastLoggedToastSegment: SponsorSegment? = nil
    /// Strong reference to the WKWebView's navigation delegate (WKWebView retains it weakly).
    private var navigationDelegate: TOSNavigationDelegate?
    /// Fires the "tickstarted" Darwin notification on the first tick received.
    /// Mutated by `handleScriptMessage(_:)` in TOSPlayerViewModel+WebBridge.swift.
    var hasReceivedFirstTick = false
    /// Prevents loadEmbed from firing in instances SwiftUI creates-then-discards during init.
    private var hasStartedLoading = false

    // MARK: - Init

    init(videoId: String, channelId: String? = nil, startTime: Double = 0, api: InnerTubeAPI) {
        self.videoId = videoId
        self.channelId = channelId
        self.startTime = startTime
        self.api = api
        self.tracker = WatchtimeTracker(api: api)

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()
        let proxyHandler = ScriptMessageProxy()
        contentController.add(proxyHandler, contentWorld: .page, name: "ytCallback")

        // Hide window.webkit BEFORE any page script runs. YouTube's embed player
        // checks window.webkit.messageHandlers to detect a WKWebView environment and
        // fires error 153 when found. Hiding it lets the player treat this as a normal
        // browser. The native ytCallback reference is saved as window.__nativeYTCallback
        // for use by stateDetectionJS (injected later at atDocumentEnd).
        let webkitHiderScript = WKUserScript(
            source: Self.webkitHiderJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        contentController.addUserScript(webkitHiderScript)

        // Inject state-detection JS into every frame at document-end.
        // The YouTube embed runs inside an <iframe> (see loadEmbed), so
        // forMainFrameOnly: false is required to reach the iframe's document.
        let detectionScript = WKUserScript(
            source: Self.stateDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        )
        contentController.addUserScript(detectionScript)

        config.userContentController = contentController

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.setValue(false, forKey: "drawsBackground")

        super.init()

        proxyHandler.target = self

        // Separate NSObject navigation delegate avoids Swift 6 @MainActor isolation
        // interfering with Objective-C WKNavigationDelegate dispatch.
        let navDel = TOSNavigationDelegate()
        self.webView.navigationDelegate = navDel
        self.navigationDelegate = navDel

        // loadEmbed is NOT called here — SwiftUI calls View.init() many times during
        // layout (creating and discarding State(initialValue:) values). Only the instance
        // that actually appears calls startIfNeeded() from onAppear.
    }

    /// Called from TOSPlayerView.onAppear. Safe to call multiple times — loads only once.
    func startIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        loadEmbed(videoId: videoId, startTime: startTime)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "ytCallback",
            contentWorld: .page
        )
    }

    // MARK: - Settings update

    /// Called from `TOSPlayerView.onAppear`. Mirrors `PlaybackViewModel.updateSettings(_:)`.
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - JS Commands (operating on YouTube embed page's <video> element)

    func play() {
        eval("var v=document.querySelector('video');if(v)v.play();")
    }

    func pause() {
        eval("var v=document.querySelector('video');if(v)v.pause();")
    }

    func seekTo(_ seconds: Double) {
        eval("var v=document.querySelector('video');if(v)v.currentTime=\(seconds);")
    }

    func setPlaybackRate(_ rate: Double) {
        eval("var v=document.querySelector('video');if(v)v.playbackRate=\(rate);")
    }

    // MARK: - Private helpers

    private func eval(_ js: String) {
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                tosLog.debug("[eval] \(js) → \(error)")
            }
        }
    }

    // MARK: - Embed URL loader

    private func loadEmbed(videoId: String, startTime: Double) {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "1"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        let embedURL = comps.url!
        tosLog.notice("[loadEmbed] loading \(embedURL)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.loadstarted" as CFString),
            nil, nil, true
        )
        // Wrap the embed URL in a minimal HTML page so YouTube's JS sees
        // window.parent !== window (iframe context). Loading the embed URL
        // directly as the top-level document makes window.parent === window,
        // which causes YouTube to fire error 153 for all videos.
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#000}
                iframe{position:absolute;top:0;left:0}
            </style>
        </head>
        <body>
            <iframe id="yt"
                src="\(embedURL.absoluteString)"
                frameborder="0"
                allow="autoplay; encrypted-media; fullscreen"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
        // Use a real baseURL so the parent page has a non-null cross-origin origin.
        // This gives iframe HTTP requests a proper Referer and Sec-Fetch-Site: cross-site
        // header (matching a legitimate third-party embed). nil/about:blank produces
        // Sec-Fetch-Site: none which some YouTube CDN nodes reject.
        // Must not be youtube.com — that would trigger YouTube's self-embed detection.
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.example.com")!)
    }

    // MARK: - WKUserScripts

    /// Injected at atDocumentStart into every frame. Hides window.webkit before any page
    /// script runs so YouTube's player can't detect the WKWebView environment. Stores
    /// the native ytCallback reference as window.__nativeYTCallback for stateDetectionJS.
    private static let webkitHiderJS: String = """
    (function() {
        try {
            var wk = window.webkit;
            if (!wk) return;
            var mh = wk.messageHandlers;
            window.__nativeYTCallback = (mh && mh.ytCallback) ? mh.ytCallback : null;
            Object.defineProperty(window, 'webkit', {
                get: function() { return undefined; },
                set: function() {},
                configurable: true,
                enumerable: false
            });
        } catch(e) {}
    })();
    """

    /// JavaScript injected at document-end into the YouTube embed page.
    /// Polls the `<video>` element and relays state via window.__nativeYTCallback
    /// (saved by webkitHiderJS before window.webkit was hidden).
    private static let stateDetectionJS: String = """
    (function() {
        try {
            var _cb = window.__nativeYTCallback;
            if (_cb) _cb.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;
        var _playAttempts = 0;

        function postMsg(obj) {
            try {
                var cb = window.__nativeYTCallback;
                if (cb) cb.postMessage(JSON.stringify(obj));
            } catch(e) {}
        }

        // Watch for YouTube's error overlay appearing in the DOM. This fires when
        // the player shows "Error 153 - Video player configuration error" (or similar)
        // instead of loading the video. MutationObserver is used so the check runs
        // asynchronously on DOM changes, not inside the pollVideo hot-path.
        var _errorReported = false;
        function checkErrorOverlay(node) {
            if (_errorReported) return;
            var errEl = node.nodeType === 1 && (
                (node.classList && node.classList.contains('ytp-error')) ||
                node.querySelector && node.querySelector('.ytp-error')
            );
            if (!errEl) return;
            _errorReported = true;
            var txt = (typeof errEl === 'object' ? (errEl.textContent || '') : (node.textContent || ''));
            var m = txt.match(/Error\\s+(\\d+)/i);
            postMsg({type: 'error', code: m ? parseInt(m[1], 10) : 153, text: txt.trim().substring(0, 200)});
        }
        var _observer = new MutationObserver(function(mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) { checkErrorOverlay(added[j]); }
            }
        });
        _observer.observe(document.documentElement, {childList: true, subtree: true});

        function pollVideo() {
            var video = document.querySelector('video');
            if (!video) return;

            var s;
            if (video.ended) {
                s = 0;
            } else if (video.paused) {
                s = 2;
            } else if (video.readyState >= 3) {
                s = 1;
            } else {
                s = 3;
            }

            var t = video.currentTime || 0;

            if (_prevState === -2) {
                _prevState = s;
                postMsg({type: 'ready', duration: video.duration || 0,
                         readyState: video.readyState, buffered: video.buffered.length});
            }

            // Kick off playback if YouTube's own autoplay didn't fire (common in WKWebView).
            // Keep retrying while paused and not yet playing (currentTime=0), up to 20 polls.
            if (video.paused && t === 0 && _playAttempts < 20) {
                _playAttempts++;
                video.muted = true;
                var p = video.play();
                if (p && p['catch']) { p['catch'](function() {}); }
            }

            postMsg({type: 'tick', t: t, state: s});

            if (s !== _prevState) {
                _prevState = s;
                postMsg({type: 'stateChange', state: s});
            }
        }

        setInterval(pollVideo, 250);
    })();
    """
}

// MARK: - TOSNavigationDelegate

/// Separate NSObject navigation delegate to ensure Objective-C dispatch works correctly
/// when the view model is a `@MainActor @Observable` actor-isolated class.
/// WKWebView holds a weak reference — TOSPlayerViewModel retains this strongly.
private final class TOSNavigationDelegate: NSObject, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Post navfinished at didCommit (document committed, before resources load).
        // Using didFinish would delay the notification until all subframes (including
        // the YouTube iframe) have loaded, but with iframe wrapping the iframe often
        // finishes after an error fires and the navigation is cancelled. didCommit
        // fires as soon as the main document is ready — reliable for the test gate.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.navfinished" as CFString),
            nil, nil, true
        )
        tosLog.notice("[nav] navigation committed (navfinished posted)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tosLog.notice("[nav] navigation finished")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        tosLog.error("[nav] provisional navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tosLog.error("[nav] navigation failed: \(error)")
    }
}

// MARK: - ScriptMessageProxy

/// Breaks the retain cycle: `WKUserContentController` retains its handlers strongly.
/// This proxy holds a `weak` reference to the real handler target so
/// `TOSPlayerViewModel` is not kept alive by the web view's content controller.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var target: TOSPlayerViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        Task { @MainActor [weak target] in
            target?.handleScriptMessage(body)
        }
    }
}

#endif // os(macOS)
