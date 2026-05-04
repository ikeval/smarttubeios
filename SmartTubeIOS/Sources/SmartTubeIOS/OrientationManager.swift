#if os(iOS)
import Foundation

/// Tracks whether the video player is currently presented on screen so that the
/// app delegate can advertise landscape-capable orientations to UIKit while the
/// player is active. Access is confined to the main actor because it is read by
/// UIApplicationDelegate (main thread) and written by PlayerView lifecycle hooks
/// (also main actor).
@MainActor
public final class OrientationManager {
    public static let shared = OrientationManager()
    private init() {}

    public var playerIsActive = false
}
#endif
