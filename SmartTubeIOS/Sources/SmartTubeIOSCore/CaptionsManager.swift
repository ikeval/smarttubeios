import Foundation

// MARK: - CaptionsManager

/// Owns caption state: `availableCaptions`, `selectedCaption`, `currentCaptionCue`,
/// `captionCues`, and `captionFetchTask`. Fully self-contained — no delegate needed.
@MainActor
@Observable
public final class CaptionsManager {

    // MARK: - State

    var availableCaptions: [CaptionTrack] = []
    var selectedCaption: CaptionTrack? = nil
    var currentCaptionCue: CaptionCue? = nil

    // Not observed (task handle, not UI state)
    @ObservationIgnored var captionCues: [CaptionCue] = []
    @ObservationIgnored var captionFetchTask: Task<Void, Never>? = nil

    // MARK: - Init

    init() {}

    // MARK: - Interface

    func reset() {
        availableCaptions = []
        selectedCaption = nil
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    func cancel() {
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    /// Selects a caption track and fetches its VTT cues. Pass `nil` to disable captions.
    /// `currentTime` is captured at call-time to update the cue immediately after fetch.
    func selectCaption(_ track: CaptionTrack?, currentTime: TimeInterval = 0) {
        selectedCaption = track
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        guard let track else { return }
        let timeToApply = currentTime
        captionFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parser = WebVTTParser()
                let cues = try await parser.fetchCues(from: track.baseURL)
                guard !Task.isCancelled else { return }
                self.captionCues = cues
                self.updateCaptionCue(for: timeToApply)
            } catch {
                // Caption fetch failed — leave cues empty
            }
        }
    }

    /// Updates `currentCaptionCue` for the given playback position.
    func updateCaptionCue(for time: TimeInterval) {
        guard !captionCues.isEmpty else { currentCaptionCue = nil; return }
        currentCaptionCue = captionCues.last(where: { $0.startTime <= time && $0.endTime > time })
    }
}
