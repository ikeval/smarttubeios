import OSLog
import SwiftUI
import SmartTubeIOSCore

private let shortsCardLog = Logger(subsystem: "com.void.smarttube.app", category: "ShortsCard")

// MARK: - ShortsCardView
//
// Portrait (9:16) card for a single YouTube Short.
// Shows the thumbnail cropped to portrait with a dark gradient overlay
// and the title text at the bottom.  Used inside ShortsRowSection.

struct ShortsCardView: View {
    let video: Video
    let onTap: () -> Void

    /// -1 = try portraitThumbnailURL (oardefault.jpg) first.
    /// -1 = try portraitThumbnailURL (oardefault.jpg) first — only when video.hasPortraitThumbnail.
    /// 0… = index into landscapeFallbacks (API thumbnailURL → sddefault → hqdefault → mqdefault).
    @State private var fallbackIndex: Int = -1

    var body: some View {
        // Only use oardefault.jpg (portrait CDN slot) when the API explicitly provided
        // a portrait thumbnail (reelItemRenderer). For Shorts detected via other signals
        // (ustreamerConfig, etc.) YouTube returns HTTP 200 with a blank black image for
        // that slot — so we skip straight to the landscape thumbnailURL instead.
        let landscapeFallbacks: [URL] = ([video.thumbnailURL] + video.thumbnailFallbackURLs).compactMap { $0 }
        let url: URL? = fallbackIndex < 0
            ? (video.hasPortraitThumbnail ? video.portraitThumbnailURL : landscapeFallbacks.first)
            : (fallbackIndex < landscapeFallbacks.count ? landscapeFallbacks[fallbackIndex] : nil)
        ZStack(alignment: .bottom) {
            // Dark background so letterboxed landscape thumbs look intentional.
            Rectangle().fill(Color.black)

            // Portrait thumbnail — scaledToFit keeps the full image visible
            // regardless of the source aspect ratio (portrait oardefault.jpg
            // fills perfectly; landscape hqdefault letterboxes top/bottom).
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure(let err):
                    let nextIndex = fallbackIndex < 0 ? 0 : fallbackIndex + 1
                    let _ = shortsCardLog.notice("ShortsCard id=\(video.id, privacy: .public) fallback=\(fallbackIndex, privacy: .public) ❌ \(url?.absoluteString ?? "nil", privacy: .public) err=\(err.localizedDescription, privacy: .public) → next=\(nextIndex < landscapeFallbacks.count ? landscapeFallbacks[nextIndex].absoluteString : "exhausted", privacy: .public)")
                    if nextIndex < landscapeFallbacks.count {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                            .onAppear { fallbackIndex = nextIndex }
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                    }
                default:
                    Rectangle().fill(Color.secondary.opacity(0.2))
                        .overlay { ProgressView() }
                }
            }
            .task(id: video.id) {
                shortsCardLog.debug("ShortsCard id=\(video.id, privacy: .public) hasPortrait=\(video.hasPortraitThumbnail, privacy: .public) apiThumb=\(video.thumbnailURL?.absoluteString ?? "nil", privacy: .public)")
                fallbackIndex = -1
            }

            // Dark gradient + title overlay at the bottom.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .overlay(alignment: .bottomLeading) {
                Text(video.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            let dur = video.formattedDuration
            if !dur.isEmpty {
                Text(dur)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
