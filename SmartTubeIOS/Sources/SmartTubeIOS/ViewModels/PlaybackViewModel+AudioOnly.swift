import AVFoundation
import os
import SmartTubeIOSCore

private let audioOnlyLog = CrashlyticsLogger(category: "AudioOnly")

// MARK: - Audio-Only Playback Mode

extension PlaybackViewModel {

    /// Entry point called from `loadAsync()` only when `isAudioOnlyMode == true`
    /// and `playerInfo` is already populated by the normal fetch.
    ///
    /// The existing HLS item is already loaded when this runs. If every audio-only
    /// attempt fails the HLS item remains active — the user gets video silently.
    func loadAudioOnlyItemIfEnabled() async {
        guard isAudioOnlyMode else { return }
        guard let info = playerInfo else { return }

        // Live streams have no adaptive audio-only URL. Leave HLS path untouched.
        guard !info.video.isLive else {
            audioOnlyLog.notice("Audio-only: skipped for live stream id=\(info.video.id)")
            return
        }

        // Attempt 1: iOS client URL (already in memory, zero extra network cost).
        if let url = info.bestAdaptiveAudioURL {
            let success = await tryLoadAudioURL(url, userAgent: InnerTubeClients.iOS.userAgent)
            if success { return }
            audioOnlyLog.notice("Audio-only: iOS client URL failed, retrying with android_vr")
        }

        // Attempt 2: android_vr client — no PO Token required for unauthenticated users.
        await retryAudioOnlyWithAndroidVR(videoId: info.video.id)
    }

    /// Builds an `AVURLAsset` for the given audio URL, checks playability, and replaces
    /// the current player item. Returns `true` on success.
    private func tryLoadAudioURL(_ url: URL, userAgent: String) async -> Bool {
        let opts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]
        ]
        let asset = AVURLAsset(url: url, options: opts)
        guard (try? await asset.load(.isPlayable)) == true else { return false }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        audioOnlyLog.notice("Audio-only: loaded \(url.absoluteString.prefix(80))")
        return true
    }

    /// Fetches player info with the android_vr client and retries loading the audio URL.
    /// Falls back to the existing HLS item (already in player) on any failure.
    private func retryAudioOnlyWithAndroidVR(videoId: String) async {
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: videoId)
            if let url = vrInfo.bestAdaptiveAudioURL {
                let success = await tryLoadAudioURL(url, userAgent: InnerTubeClients.AndroidVR.userAgent)
                if success { return }
            }
        } catch {
            audioOnlyLog.error("Audio-only: android_vr fetch failed: \(error)")
        }

        // Both attempts failed — the HLS item is already in the player. Reset the flag
        // so the UI re-shows the video layer rather than a blank thumbnail overlay.
        audioOnlyLog.notice("Audio-only: all attempts failed, falling back to HLS")
        isAudioOnlyMode = false
    }
}
