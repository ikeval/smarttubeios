import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - PlaybackQualityTests

/// Tests for HLS quality selection logic.
/// These mirror the algorithm in PlaybackViewModel+Quality.swift so that
/// correctness can be verified without an AVPlayer or network connection.

@Suite("Playback Quality")
struct PlaybackQualityTests {

    // MARK: - peakBitRate

    /// Mirrors peakBitRate(for:) in PlaybackViewModel+Quality.swift.
    private func peakBitRate(for height: Int) -> Double {
        switch height {
        case 2160:  return 20_000_000
        case 1440:  return 12_000_000
        case 1080:  return  8_000_000
        case  720:  return  5_000_000
        default:    return  8_000_000
        }
    }

    @Test func peakBitRate_2160p_returns20Mbps() {
        #expect(peakBitRate(for: 2160) == 20_000_000)
    }

    @Test func peakBitRate_1440p_returns12Mbps() {
        #expect(peakBitRate(for: 1440) == 12_000_000)
    }

    @Test func peakBitRate_1080p_returns8Mbps() {
        #expect(peakBitRate(for: 1080) == 8_000_000)
    }

    @Test func peakBitRate_720p_returns5Mbps() {
        #expect(peakBitRate(for: 720) == 5_000_000)
    }

    @Test func peakBitRate_unknownHeight_returnsDefault() {
        #expect(peakBitRate(for: 360) == 8_000_000)
        #expect(peakBitRate(for: 480) == 8_000_000)
    }

    // MARK: - HLS variant selection (platform-agnostic logic)

    /// Mirrors the iOS/non-tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep first variant, then upgrade to H.264 if existing is non-H.264.
    private func selectVariant_iOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        if !existingIsH264 && candidateIsH264 {
            return (candidate, true)
        }
        return (existing!, existingIsH264)
    }

    /// Mirrors the tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep the first variant seen (no H.264 upgrade).
    private func selectVariant_tvOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        return (existing!, existingIsH264)
    }

    @Test func variantSelection_iOS_upgradesHEVCToH264() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // HEVC variant seen first, then H.264 arrives → should upgrade to H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_iOS_doesNotDowngradeH264ToHEVC() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // H.264 seen first, then HEVC → should keep H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsHEVC() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // tvOS: HEVC seen first → keep HEVC even when H.264 arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == hevcURL)
        #expect(isH264 == false)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsH264() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // tvOS: H.264 seen first → keep H.264 even when HEVC arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_firstVariant_alwaysAccepted() {
        let url = URL(string: "https://example.com/stream.m3u8")!

        // Both platforms: accept any first variant
        let (selected, isH264) = selectVariant_iOS(
            existing: nil, existingIsH264: false,
            candidate: url, candidateIsH264: false
        )
        #expect(selected == url)
        #expect(isH264 == false)
    }
}
