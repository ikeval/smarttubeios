import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SwipeGestureOverlay

#if os(iOS)
/// A transparent UIKit view that captures pan and tap gestures before
/// AVPlayerViewController can consume them.
///
/// - `cancelsTouchesInView = false` lets taps still reach controls below.
/// - `require(toFail:)` is called against every sibling recognizer in the
///   window so this pan always wins when predominantly vertical.
struct SwipeGestureOverlay: UIViewRepresentable {
    var onSwipeUp:        () -> Void
    var onSwipeDown:      () -> Void
    var onTap:            () -> Void
    var onTwoFingerTap:   () -> Void = {}
    var onPanChanged:     ((CGFloat) -> Void)?
    var onSwipeCancelled: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: SwipeGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: SwipeGestureOverlay) { self.parent = parent }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            switch gr.state {
            case .changed:
                parent.onPanChanged?(t.y)
            case .ended:
                guard abs(t.y) > minDistance, abs(t.y) > abs(t.x) else {
                    parent.onSwipeCancelled?()
                    return
                }
                if t.y < 0 { parent.onSwipeUp() } else { parent.onSwipeDown() }
            case .cancelled, .failed:
                parent.onSwipeCancelled?()
            default:
                break
            }
        }

        @MainActor @objc func handleTap() { parent.onTap() }
        @MainActor @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }
    }
}
#endif
