import Foundation

// MARK: - InnerTubeClients
//
// Single source of truth for YouTube InnerTube client identifiers and versions.
// Used by InnerTubeAPI (request bodies + headers) and AuthService (TV context body).

package enum InnerTubeClients {

    package enum Web {
        package static let name      = "WEB"
        package static let nameID    = "1"
        package static let version   = "2.20260206.01.00"
        /// Browser UA used by the YouTube web client.
        package static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    package enum iOS {
        package static let name      = "iOS"
        package static let nameID    = "5"
        package static let version   = "21.02.3"
        /// Returns the running iOS version formatted as "MAJOR_MINOR_PATCH" (or "MAJOR_MINOR"
        /// when the patch is 0). Dynamically derived from ProcessInfo so the User-Agent always
        /// reflects the actual device OS — prevents YouTube from rejecting requests sent from
        /// devices running iOS versions newer than the hardcoded string.
        package static var currentOSVersionString: String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return v.patchVersion == 0
                ? "\(v.majorVersion)_\(v.minorVersion)"
                : "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        }
        package static var userAgent: String {
            "com.google.ios.youtube/\(version) (iPhone16,2; U; CPU iOS \(currentOSVersionString) like Mac OS X;)"
        }
    }

    /// Android client — used exclusively for downloads.
    /// CDN URLs signed by the Android client are reliably downloadable using just
    /// the Android UA; no session cookies or PO tokens required.
    /// Exact params from yt-dlp to avoid YouTube bot detection / HTTP 400.
    package enum Android {
        package static let name            = "ANDROID"
        package static let nameID          = "3"
        package static let version         = "21.02.35"
        package static let androidSdkVersion = 30  // Android 11
        package static let userAgent       = "com.google.android.youtube/\(version) (Linux; U; Android 11) gzip"
    }

    /// Android VR client (Oculus Quest identity) — used as an unauthenticated fallback
    /// for audio-only mode. Per yt-dlp research (May 2026), this client does not require
    /// a Proof-of-Origin (PO) token for adaptive streams. Monitor for future enforcement.
    /// Note: clientVersion must not exceed 1.65 — higher versions return SABR streams only.
    package enum AndroidVR {
        package static let name    = "ANDROID_VR"
        package static let nameID  = "28"
        package static let version = "1.65.10"
        // eureka-user build string matches yt-dlp's android_vr UA exactly (May 2026).
        package static let userAgent = "com.google.android.apps.youtube.vr.oculus/\(version) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    }

    /// TV Embedded client (TVHTML5_SIMPLY_EMBEDDED_PLAYER) — used for YouTube iframe embeds.
    /// Returns an HLS manifest for most videos without requiring a PO token, making it
    /// ideal as a fallback when iOS/Android adaptive streams have rqh=1 enforcement.
    package enum TVEmbedded {
        package static let name    = "TVHTML5_SIMPLY_EMBEDDED_PLAYER"
        package static let nameID  = "85"
        package static let version = "2.0"
    }

    /// YouTube Studio (creator) web client. Per yt-dlp research, this client is exempt
    /// from Proof-of-Origin (rqh=1) CDN enforcement on adaptive streams, unlike the
    /// standard WEB (1), iOS (5), or Android (3) clients. Its adaptive stream URLs can
    /// be used in AVMutableComposition without a pot= token.
    package enum WebCreator {
        package static let name    = "WEB_CREATOR"
        package static let nameID  = "62"
        package static let version = "1.20240723.03.00"
    }

    package enum TV {
        package static let name      = "TVHTML5"
        package static let nameID    = "7"
        // Use yt-dlp's tv_downgraded version (5.x) for authenticated requests.
        // Version 7.x is the unauthenticated Cobalt client; version 5.x (tv_downgraded)
        // is YouTube's authenticated TV client and returns hlsManifestUrl for standard
        // videos, enabling native AVPlayer ABR quality switching without composition.
        package static let version   = "5.20260114"
        package static let userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    }

    /// Maximum number of videos fetched per shelf/related-videos request.
    package static let maxVideoResults = 20
}
