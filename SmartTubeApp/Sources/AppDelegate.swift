#if os(iOS)
import UIKit
import SmartTubeIOS

/// Provides the per-screen orientation mask that UIKit queries for every view
/// controller. Returns `.allButUpsideDown` while the video player is on screen
/// so that `UIWindowScene.requestGeometryUpdate` can successfully request
/// landscape. Returns `.portrait` at all other times so the rest of the app
/// stays in portrait.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.playerIsActive ? .allButUpsideDown : .portrait
    }
}
#endif
