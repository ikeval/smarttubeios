import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - HideShortsFilterTests
//
// Unit-tests the `hideShorts` filter predicate used in SearchView,
// LibraryView, ChannelView, and RSSFeedsView:
//
//   videos.filter { !settings.hideShorts || !$0.isShort }
//
// All assertions are pure value transforms — no SwiftUI, no network.

@Suite("Hide Shorts filter predicate")
struct HideShortsFilterTests {

    // MARK: - Helpers

    private func makeVideo(id: String, isShort: Bool) -> Video {
        Video(id: id, title: id, channelTitle: "ch", isShort: isShort)
    }

    /// Applies the same predicate used in the fixed views.
    private func apply(hideShorts: Bool, to videos: [Video]) -> [Video] {
        videos.filter { !hideShorts || !$0.isShort }
    }

    // MARK: - hideShorts == false (default)

    @Test("When hideShorts is false, all videos are returned including Shorts")
    func hideShortsDisabledPassesAll() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: true),
            makeVideo(id: "c", isShort: false),
            makeVideo(id: "d", isShort: true),
        ]
        let result = apply(hideShorts: false, to: videos)
        #expect(result.count == 4)
        #expect(result.map(\.id) == ["a", "b", "c", "d"])
    }

    // MARK: - hideShorts == true

    @Test("When hideShorts is true, Short videos are removed")
    func hideShortsEnabledRemovesShorts() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: true),
            makeVideo(id: "c", isShort: false),
            makeVideo(id: "d", isShort: true),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.count == 2)
        #expect(result.map(\.id) == ["a", "c"])
    }

    @Test("When hideShorts is true and all videos are Shorts, result is empty")
    func hideShortsEnabledAllShortsReturnsEmpty() {
        let videos = [
            makeVideo(id: "a", isShort: true),
            makeVideo(id: "b", isShort: true),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.isEmpty)
    }

    @Test("When hideShorts is true and no videos are Shorts, all are returned")
    func hideShortsEnabledNoShortsPassesAll() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: false),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.count == 2)
    }

    @Test("Empty input produces empty output regardless of hideShorts")
    func emptyInputAlwaysEmpty() {
        #expect(apply(hideShorts: false, to: []).isEmpty)
        #expect(apply(hideShorts: true,  to: []).isEmpty)
    }

    // MARK: - AppSettings default

    @Test("AppSettings default has hideShorts == false")
    func appSettingsDefaultHideShortsFalse() {
        let settings = AppSettings()
        #expect(settings.hideShorts == false)
    }
}
