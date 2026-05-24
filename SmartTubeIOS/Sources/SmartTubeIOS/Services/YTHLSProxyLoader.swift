/// YTHLSProxyLoader.swift
/// Proxies HLS playlist and segment requests through URLSession so the correct
/// User-Agent (desktop Safari) is sent to manifest.googlevideo.com.
/// AVURLAssetHTTPHeaderFieldsKey does not reliably propagate User-Agent through
/// CoreMedia's internal HLS stack — this resource loader fills that gap.

#if canImport(WebKit)
import AVFoundation
import Foundation
import os.log

private let proxyScheme = "ytwebhls"
private let proxyLog = Logger(subsystem: "com.void.smarttube.app", category: "HLSProxy")

// MARK: - URL scheme helpers

extension URL {
    /// Converts an https:// URL to ytwebhls:// for routing through the proxy.
    var proxyURL: URL? {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = proxyScheme
        return c.url
    }
    /// Converts a ytwebhls:// URL back to https:// for the actual network request.
    var realURL: URL? {
        guard scheme == proxyScheme,
              var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        return c.url
    }
}

// MARK: - YTHLSProxyLoader

/// `AVAssetResourceLoaderDelegate` that forwards every HLS request through
/// `URLSession.shared` with a desktop-Safari User-Agent header.
/// Holds a strong reference to itself via the asset to keep it alive.
final class YTHLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let ua: String
    /// When non-nil, the proxy rewrites all `/n/{unsolved}/` occurrences to `/n/{solved}/`
    /// in HLS playlist text before serving it to AVPlayer. This makes segment URLs carry
    /// the solved n-challenge so the video CDN accepts them (HTTP 200 instead of 403).
    let nSolver: (unsolved: String, solved: String)?
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(ua: String, nSolver: (unsolved: String, solved: String)? = nil) {
        self.ua = ua
        self.nSolver = nSolver
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              let realURL   = proxyURL.realURL else {
            proxyLog.error("[HLSProxy] unexpected scheme: \(loadingRequest.request.url?.scheme ?? "nil")")
            return false
        }

        var request = URLRequest(url: realURL, timeoutInterval: 30)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        // HLS segment CDN (googlevideo.com) uses no-cors in browsers — no Origin/Referer.
        // Only add these headers for manifest.googlevideo.com (playlist) requests.
        if realURL.host?.hasPrefix("manifest.") == true {
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        }
        // For googlevideo.com segment CDN requests, attach the youtube.com session cookies
        // that were synced from the WKWebView during HLS extraction.  The CDN validates the
        // per-segment /bui/ token against VISITOR_INFO1_LIVE (and possibly YSC/PREF).
        // Without these cookies the CDN returns HTTP 403 for pfa=1 content.
        if let host = realURL.host, host.contains("googlevideo.com"),
           let ytCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.youtube.com")!),
           !ytCookies.isEmpty {
            let cookieHeader = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            proxyLog.notice("[HLSProxy] attaching \(ytCookies.count) yt cookies to segment request")
        }
        proxyLog.notice("[HLSProxy] GET \(realURL.absoluteString.prefix(200))")

        // For diagnostics: log the full URL of the first segment request so we can probe it
        if realURL.host?.contains("googlevideo.com") == true && realURL.absoluteString.count > 200 {
            proxyLog.notice("[HLSProxy] fullURL[A] \(realURL.absoluteString.prefix(400))")
            if realURL.absoluteString.count > 400 {
                proxyLog.notice("[HLSProxy] fullURL[B] \(realURL.absoluteString.dropFirst(400))")
            }
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.activeTasks.removeValue(forKey: key)
                self.lock.unlock()
            }

            if let error {
                proxyLog.error("[HLSProxy] URLSession error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let httpResp = response as? HTTPURLResponse, let data else {
                loadingRequest.finishLoading(with: NSError(domain: "YTHLSProxy", code: -1))
                return
            }

            proxyLog.notice("[HLSProxy] \(realURL.lastPathComponent) HTTP=\(httpResp.statusCode) bytes=\(data.count)")

            // Populate content information
            if let infoReq = loadingRequest.contentInformationRequest {
                let ct = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "application/x-mpegURL"
                infoReq.contentType = ct
                infoReq.contentLength = Int64(data.count)
                infoReq.isByteRangeAccessSupported = false
            }

            // For HLS playlists, rewrite segment/sub-playlist URIs to our proxy scheme
            var responseData = data
            let ct = httpResp.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.contains("mpegurl") || realURL.pathExtension == "m3u8" || realURL.path.contains("playlist") {
                if let text = String(data: data, encoding: .utf8) {
                    // Log first 600 chars of the playlist to see segment URL format
                    proxyLog.notice("[HLSProxy] playlist head: \(text.prefix(600))")
                    let rewritten = self.rewritePlaylist(text, baseURL: realURL)
                    responseData = rewritten.data(using: .utf8) ?? data
                }
            }

            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }

        lock.lock()
        activeTasks[key] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = activeTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    // MARK: Playlist rewriting

    /// Rewrites all URI lines in an HLS M3U8 to use our proxy scheme so that
    /// AVPlayer routes segment/sub-playlist requests through this delegate.
    /// Also rewrites the n-challenge in all segment/playlist URLs if `nSolver` is set.
    private func rewritePlaylist(_ m3u8: String, baseURL: URL) -> String {
        // Step 1: Replace unsolved n-challenge across the entire playlist text.
        // The n-value is identical in all URLs for a given session, so a global
        // string replacement is safe and avoids per-URL regex overhead.
        var text = m3u8
        if let (unsolved, solved) = nSolver, !unsolved.isEmpty, unsolved != solved {
            let oldN = "/n/\(unsolved)/"
            let newN = "/n/\(solved)/"
            let before = text
            text = text.replacingOccurrences(of: oldN, with: newN)
            if text != before {
                proxyLog.notice("[HLSProxy] n-challenge rewritten: \(unsolved as NSString) -> \(solved as NSString)")
            } else {
                proxyLog.notice("[HLSProxy] n-challenge NOT found in playlist (unsolved=\(unsolved as NSString))")
            }
        }

        // Step 2: Rewrite all absolute/relative URIs to use the ytwebhls:// proxy scheme.
        let baseDir = baseURL.deletingLastPathComponent()
        var lines = text.components(separatedBy: "\n")
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            // Skip empty lines and M3U8 tags
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Resolve relative URIs against the base directory
            let absoluteURL: URL
            if line.hasPrefix("https://") || line.hasPrefix("http://") {
                guard let u = URL(string: line) else { continue }
                absoluteURL = u
            } else if line.hasPrefix("//") {
                guard let u = URL(string: "https:" + line) else { continue }
                absoluteURL = u
            } else {
                guard let u = URL(string: line, relativeTo: baseDir)?.absoluteURL else { continue }
                absoluteURL = u
            }

            if let proxied = absoluteURL.proxyURL {
                lines[i] = proxied.absoluteString
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
