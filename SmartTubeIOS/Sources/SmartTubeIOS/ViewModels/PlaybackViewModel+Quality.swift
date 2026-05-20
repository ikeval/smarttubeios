import AVFoundation
import SmartTubeIOSCore

// MARK: - Stream Format / HLS Quality Selection (thin wrapper — logic lives in PlaybackQualityManager)

extension PlaybackViewModel {

    public func selectFormat(_ format: VideoFormat?) {
        qualityManager.selectFormat(format)
        // Refresh Stats for Nerds immediately so the overlay shows the new quality
        // without waiting for the next periodic-observer tick (which may not fire
        // while the player is loading the replacement item).
        if statsForNerdsVisible { updateStatsSnapshot() }
    }

    func reloadHLSItem(seekTo time: TimeInterval, quality: AppSettings.VideoQuality) async {
        await qualityManager.reloadHLSItem(seekTo: time, quality: quality)
    }

    func fetchHLSVariantURLs(url: URL) async -> [Int: URL] {
        await qualityManager.fetchHLSVariantURLs(url: url)
    }

    static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        PlaybackQualityManager.deduplicatedVideoFormats(formats)
    }

    func peakBitRate(for height: Int) -> Double {
        qualityManager.peakBitRate(for: height)
    }

    func reloadHLSItemH264Capped(seekTo time: TimeInterval) async {
        await qualityManager.reloadHLSItemH264Capped(seekTo: time)
    }
}
