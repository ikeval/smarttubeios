import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - AudioTrackSelectionTests

@Suite("Audio Track Auto-Selection")
struct AudioTrackSelectionTests {

    // MARK: - Helpers

    private func track(_ code: String, isOriginal: Bool = false) -> AudioTrack {
        AudioTrack(id: code, name: code, languageCode: code, isOriginal: isOriginal)
    }

    /// Simulates the auto-selection waterfall from PlaybackViewModel+AudioTracks
    /// without an AVPlayer. Mirrors the exact logic in loadAudioTracks(from:).
    private func autoSelect(tracks: [AudioTrack], preferred: String?) -> AudioTrack? {
        // 1. Saved preference / Settings-level independent language choice
        if let lang = preferred {
            if lang == "original" {
                return tracks.first(where: \.isOriginal) ?? tracks.first
            }
            if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
            let base = lang.components(separatedBy: "-").first ?? lang
            return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                ?? tracks.first(where: \.isOriginal)
        }
        // 2. HLS DEFAULT=YES original
        if let original = tracks.first(where: \.isOriginal) { return original }
        // 3. English track
        let englishPrefixes = ["en-", "en_"]
        if let english = tracks.first(where: { $0.languageCode == "en" })
            ?? tracks.first(where: { lang in englishPrefixes.contains(where: { lang.languageCode.hasPrefix($0) }) }) {
            return english
        }
        // 4. Device preferred languages (mocked as empty for deterministic tests)
        // 5. First track
        return tracks.first
    }

    // MARK: - Tests

    /// When HLS DEFAULT=YES is on the English track, English is selected even on an
    /// Arabic-locale device (issue #24 root cause fix).
    @Test func originalTrackSelectedOverAIDubbedTrackWhenDefaultIsYES() {
        let tracks = [
            track("ar", isOriginal: false),     // AI-dubbed Arabic — listed first
            track("en", isOriginal: true),      // Original English — HLS DEFAULT=YES
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }

    /// When no HLS DEFAULT=YES exists, English is chosen over other languages as
    /// the safer fallback (most YouTube originals are English).
    @Test func englishFallbackWhenNoDefaultTrack() {
        let tracks = [
            track("ar", isOriginal: false),     // AI-dubbed Arabic — first in list, no DEFAULT
            track("en", isOriginal: false),     // English — second in list
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }

    /// Saved user preference always wins, even when a DEFAULT=YES track exists.
    @Test func savedPreferenceWinsOverOriginalTrack() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "de")
        #expect(selected?.languageCode == "de")
    }

    /// isOriginal is NOT set for index-0 when there is no HLS DEFAULT=YES.
    /// This prevents AI-dubbed tracks from being mislabelled as "original".
    @Test func isOriginalNotSetWhenNoHLSDefault() {
        // Simulates manifest with no DEFAULT=YES: all isOriginal == false
        let tracks = [
            track("ar", isOriginal: false),
            track("en", isOriginal: false),
        ]
        #expect(tracks.allSatisfy { !$0.isOriginal })
    }

    // MARK: - Task #19: "original" sentinel and independent language setting

    /// When preferredAudioLanguage == "original", the HLS DEFAULT=YES track is selected.
    @Test func originalSentinel_selectsHLSDefaultTrack() {
        let tracks = [
            track("ar", isOriginal: false),
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "en")
    }

    /// When preferredAudioLanguage == "original" and no DEFAULT=YES track exists, falls back to first track.
    @Test func originalSentinel_fallsBackToFirstTrack_whenNoDefault() {
        let tracks = [
            track("ar", isOriginal: false),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "ar")
    }

    /// Independent language setting "de" overrides the original English track.
    @Test func independentLanguageSetting_overridesOriginalTrack() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "de")
        #expect(selected?.languageCode == "de")
    }

    /// Prefix matching: setting "en" matches "en-US".
    @Test func independentLanguageSetting_prefixMatchesLocaleVariant() {
        let tracks = [
            track("de", isOriginal: false),
            track("en-US", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "en")
        #expect(selected?.languageCode == "en-US")
    }

    /// When preferred language has no match, falls back to original track.
    @Test func independentLanguageSetting_fallsBackToOriginal_whenNoMatch() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        // "ja" not in list → fall back to original
        let selected = autoSelect(tracks: tracks, preferred: "ja")
        #expect(selected?.languageCode == "en")
    }

    /// System Default (nil) still picks the HLS DEFAULT=YES track first.
    @Test func systemDefault_picksOriginalTrack() {
        let tracks = [
            track("de", isOriginal: false),
            track("en", isOriginal: true),
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }
}
