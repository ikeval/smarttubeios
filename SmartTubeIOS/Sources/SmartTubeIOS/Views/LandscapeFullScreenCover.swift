#if os(iOS)
import SwiftUI
import UIKit
import SmartTubeIOSCore
import OSLog

private let landscapeLog = Logger(subsystem: "com.void.smarttube.app", category: "Orientation")

// MARK: - LandscapeAwareHostingController

/// UIHostingController whose supportedInterfaceOrientations returns .allButUpsideDown
/// while OrientationManager.shared.playerIsActive is true. This replaces SwiftUI's
/// internal PresentationHostingController (which hard-locks to portrait) so that UIKit
/// accepts requestGeometryUpdate(.landscape) and honours physical device rotations
/// while the player is on screen.
final class LandscapeAwareHostingController: UIHostingController<AnyView> {
    var onDismiss: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationManager.shared.playerIsActive ? .allButUpsideDown : .portrait
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            landscapeLog.notice("[LandscapeAwareHostingController] viewDidDisappear isBeingDismissed=true — calling onDismiss")
            onDismiss?()
        }
    }
}

// MARK: - landscapePlayerCover modifier

extension View {
    /// Drop-in replacement for `.fullScreenCover(item:content:)` when presenting
    /// PlayerView on iOS. Hosts the content in a `LandscapeAwareHostingController`
    /// so UIKit can rotate the window to landscape while the player is active.
    func landscapePlayerCover<Item: Identifiable & Hashable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.background(
            LandscapePresenter(item: item, content: { AnyView(content($0)) })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - LandscapePresenter (UIViewControllerRepresentable)

private struct LandscapePresenter<Item: Identifiable & Hashable>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let content: (Item) -> AnyView

    // Capture the env objects that PlayerView (and anything it hosts) needs.
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var authService

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.latestItem = item
        // Wrap the content with the environment objects so the new UIHostingController
        // root gets the same env as the parent SwiftUI tree.
        let capturedStore = store
        let capturedAuth = authService
        coordinator.contentBuilder = { [content] item in
            AnyView(
                content(item)
                    .environment(capturedStore)
                    .environment(capturedAuth)
            )
        }
        coordinator.latestBinding = _item

        // Defer UIKit presentation to the next run-loop tick to avoid calling
        // UIKit presentation APIs during a SwiftUI layout/update pass.
        // Capture the generation so stale tasks queued before an onDismiss are no-ops.
        let capturedGen = coordinator.presentationGeneration
        Task { @MainActor in
            guard coordinator.presentationGeneration == capturedGen else { return }
            guard let window = vc.view.window,
                  let root = window.rootViewController else { return }
            coordinator.sync(root: root)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator {
        var latestItem: Item?
        var contentBuilder: ((Item) -> AnyView)?
        var latestBinding: Binding<Item?>?
        var hostedVC: LandscapeAwareHostingController?
        var presentedID: AnyHashable?
        var isTransitioning = false
        /// Incremented on dismiss; Tasks capture the value at creation and abort if it changed.
        var presentationGeneration = 0
        /// After a dismiss, block re-presentations until this date. Prevents the
        /// SwiftUI binding oscillation that occurs when playerIsActive toggles and
        /// UIKit re-queries orientations, causing updateUIViewController(nil) followed
        /// by updateUIViewController(video) within the same run-loop batch.
        var suppressPresentUntil: Date = .distantPast
        /// When the current player was presented. Used to ignore spurious nil updates
        /// that arrive immediately after a present (while UIKit is settling).
        var presentedAt: Date = .distantPast

        func sync(root: UIViewController) {

            guard !isTransitioning else { return }

            if let currentItem = latestItem {
                // Already presenting this exact item — nothing to do.
                guard presentedID != AnyHashable(currentItem.id) else { return }
                guard let contentBuilder else { return }

                // Suppress rapid re-presentation while SwiftUI/UIKit binding is settling
                // after a dismiss (binding can oscillate between nil and video).
                guard Date() >= suppressPresentUntil else {
                    landscapeLog.notice("[LandscapePresenter] sync — suppressing present (within dismiss window)")
                    return
                }

                isTransitioning = true

                func doPresent() {
                    // Walk to the topmost presenter that is NOT being dismissed
                    // BEFORE creating the new VC, so an abort leaves hostedVC/presentedID
                    // intact and prevents immediate re-presentation.
                    var top = root
                    while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
                    // Bail if the top VC is unavailable or still has a child being dismissed.
                    // Keep presentedID unchanged so subsequent Tasks see the same item ID
                    // and short-circuit; onDismiss will clear everything when the
                    // in-flight dismiss animation completes.
                    guard top.view.window != nil,
                          !top.isBeingDismissed,
                          top.presentedViewController == nil else {
                        landscapeLog.notice("[LandscapePresenter] doPresent — top VC not available, aborting")
                        self.isTransitioning = false
                        return
                    }

                    let hc = LandscapeAwareHostingController(rootView: contentBuilder(currentItem))
                    hc.modalPresentationStyle = .fullScreen
                    hc.onDismiss = { [weak self] in
                        landscapeLog.notice("[LandscapePresenter] onDismiss — clearing binding and hosted VC")
                        // Suppress new presentations for 0.5 s while the SwiftUI binding
                        // and UIKit orientation state settle after the dismiss.
                        self?.suppressPresentUntil = Date().addingTimeInterval(0.5)
                        // Invalidate all Tasks queued before this dismiss fires.
                        self?.presentationGeneration += 1
                        self?.latestItem = nil
                        self?.latestBinding?.wrappedValue = nil
                        self?.hostedVC = nil
                        self?.presentedID = nil
                        self?.isTransitioning = false
                    }
                    self.hostedVC = hc
                    self.presentedID = AnyHashable(currentItem.id)
                    self.presentedAt = Date()
                    landscapeLog.notice("[LandscapePresenter] presenting LandscapeAwareHostingController from \(type(of: top))")
                    top.present(hc, animated: false) { [weak self] in
                        self?.isTransitioning = false
                    }
                }

                if let existing = hostedVC, existing.presentingViewController != nil {
                    landscapeLog.notice("[LandscapePresenter] dismissing existing VC before presenting new")
                    existing.dismiss(animated: false) { doPresent() }
                } else {
                    doPresent()
                }

            } else {
                // item == nil — dismiss the hosted VC if still on screen.
                // Ignore spurious nils that arrive within 0.5 s of the present
                // (UIKit orientation re-queries can cause immediate nil updates).
                guard Date() >= presentedAt.addingTimeInterval(0.5) else {
                    landscapeLog.notice("[LandscapePresenter] item nil — ignoring spurious nil (within present window)")
                    return
                }
                guard let hc = hostedVC else {
                    presentedID = nil
                    return
                }
                guard !hc.isBeingDismissed else { return }
                guard hc.presentingViewController != nil else {
                    hostedVC = nil
                    presentedID = nil
                    return
                }
                landscapeLog.notice("[LandscapePresenter] item nil — dismissing LandscapeAwareHostingController")
                isTransitioning = true
                hostedVC = nil
                presentedID = nil
                hc.dismiss(animated: false) { [weak self] in
                    self?.isTransitioning = false
                }
            }
        }
    }
}
#endif
