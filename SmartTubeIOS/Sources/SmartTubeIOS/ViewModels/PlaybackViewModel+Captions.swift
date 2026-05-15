import Foundation
import SmartTubeIOSCore

// MARK: - Caption Track Selection (thin wrapper — logic lives in CaptionsManager)

extension PlaybackViewModel {

    public func selectCaption(_ track: CaptionTrack?) {
        captionsManager.selectCaption(track, currentTime: currentTime)
    }

    func updateCaptionCue(for time: TimeInterval) {
        captionsManager.updateCaptionCue(for: time)
    }
}
