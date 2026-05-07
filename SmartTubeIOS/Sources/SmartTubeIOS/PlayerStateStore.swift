#if os(iOS)
import AVFoundation
import UIKit
import Observation
import SmartTubeIOSCore

// MARK: - PersistentPlayerHostView

/// A UIView that owns an AVPlayerLayer for the lifetime of the app.
/// Its reference lives in PlayerStateStore, so the layer — and the AVPlayer
/// connection — survive PlayerView dismiss/re-present cycles (mini-player).
///
/// Embed it as a subview in full-screen and mini-player contexts.
/// UIView.addSubview automatically removes it from the previous parent,
/// so no explicit removeFromSuperview is needed when transplanting.
final class PersistentPlayerHostView: UIView {

    let playerLayer = AVPlayerLayer()

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - PlayerStateStore

/// Centralised iOS playback state for the in-app mini-player.
///
/// Owns the single `PlaybackViewModel` and `PersistentPlayerHostView` so they
/// survive PlayerView presentation/dismiss cycles. Injected as an environment
/// object at the `AppEntry` level; accessed via `@Environment(PlayerStateStore.self)`.
@MainActor
@Observable
public final class PlayerStateStore {

    // MARK: - Presentation state

    public enum Presentation: Equatable {
        case hidden
        case miniPlayer
        case fullScreen
    }

    public private(set) var presentation: Presentation = .hidden

    /// The video that is currently loaded or playing. Non-nil when presentation != .hidden.
    private(set) var currentVideo: Video? = nil

    // MARK: - Owned objects

    /// The single PlaybackViewModel for the app. Lives for the app's lifetime.
    public let vm: PlaybackViewModel

    /// The UIView that owns the AVPlayerLayer. Never deallocated; transplanted
    /// between full-screen and mini-player containers via UIView.addSubview.
    let playerHostView: PersistentPlayerHostView

    // MARK: - Init

    public init(api: InnerTubeAPI) {
        let vm = PlaybackViewModel(api: api)
        self.vm = vm
        let hostView = PersistentPlayerHostView()
        hostView.playerLayer.player = vm.player
        self.playerHostView = hostView
    }

    // MARK: - Actions

    /// Load `video` (if not already loaded) and present the full-screen player.
    func play(video: Video) {
        if vm.currentVideoId != video.id {
            vm.load(video: video)
        }
        currentVideo = video
        presentation = .fullScreen
    }

    /// Collapse the full-screen player to the mini-player bar. Playback continues.
    func minimize() {
        presentation = .miniPlayer
    }

    /// Expand the mini-player back to full-screen.
    func expand() {
        presentation = .fullScreen
    }

    /// Stop playback completely and hide the player UI.
    func stop() {
        vm.stop()
        currentVideo = nil
        presentation = .hidden
    }
}
#endif
