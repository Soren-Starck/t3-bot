import UIKit

/// Back gestures for every pushed screen (a chat, all needs, done without you), with public API only:
/// - the edge swipe keeps working although the chat hides the system navigation bar;
/// - a swipe to the right from anywhere on the screen goes back too. iOS 26 has its own recognizer for that
///   (`interactiveContentPopGestureRecognizer`), and UIKit drives the real back transition with it (the chat follows
///   the finger and home slides in underneath). It only starts on a mostly horizontal, rightward swipe, so scrolling,
///   text selection and the leftward row swipes (Done, Not now) are untouched;
/// - if that recognizer is missing, or starts no transition, the same swipe still goes back with the normal animated
///   pop, so the gesture never goes dead.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        let content = interactiveContentPopGestureRecognizer
        content?.delegate = self
        content?.addTarget(self, action: #selector(t3botSystemBackMoved(_:)))
        // The fallback: it waits for the system recognizer to give up, so the two never both go back.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(t3botFallbackBack(_:)))
        pan.delegate = self
        pan.name = SwipeBack.fallbackName
        if let content { pan.require(toFail: content) }
        view.addGestureRecognizer(pan)
    }

    /// The system's full-width recognizer moved. When it began and UIKit started no transition, the swipe still
    /// goes back once it ends as a clear swipe to the right.
    @objc func t3botSystemBackMoved(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .began:
            SwipeBack.systemIdle = false
            DispatchQueue.main.async { [weak self] in SwipeBack.systemIdle = self?.transitionCoordinator == nil }
        case .ended:
            let idle = SwipeBack.systemIdle
            SwipeBack.systemIdle = false
            guard idle, transitionCoordinator == nil, viewControllers.count > 1,
                  let pan = recognizer as? UIPanGestureRecognizer, SwipeBack.wentBack(pan, in: view) else { return }
            popViewController(animated: true)
        case .cancelled, .failed:
            SwipeBack.systemIdle = false
        default:
            break
        }
    }

    @objc func t3botFallbackBack(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, viewControllers.count > 1, transitionCoordinator == nil, SwipeBack.wentBack(pan, in: view) else { return }
        popViewController(animated: true)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
        let fullWidth = gestureRecognizer.name == SwipeBack.fallbackName || gestureRecognizer === interactiveContentPopGestureRecognizer
        if fullWidth, let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let v = pan.velocity(in: view)
            guard v.x > 120, abs(v.x) > abs(v.y) * 1.6 else { return false }
            // Judged where the finger came down, not where it is now: by the time a pan may begin it has moved.
            let now = pan.location(in: view)
            let moved = pan.translation(in: view)
            let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
            return !SwipeBack.scrollsBack(at: start, in: view)
        }
        return true
    }

    /// The full-width back swipe wins over the chat's vertical scrolling only when it is clearly horizontal (checked
    /// above); horizontal strips (quick replies, photos) still scroll when swiped left.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

enum SwipeBack {
    static let fallbackName = "t3bot.fullWidthBack"
    /// True while the system recognizer is tracking a swipe that started no transition.
    static var systemIdle = false

    /// True when the touch is on a sideways strip (a code block, a table, quick replies, photos) that is scrolled
    /// away from its start: a swipe to the right there scrolls the strip back and does not leave the screen.
    static func scrollsBack(at point: CGPoint, in view: UIView) -> Bool {
        var hit: UIView? = view.hitTest(point, with: nil)
        while let current = hit, current !== view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                return true
            }
            hit = current.superview
        }
        return false
    }

    /// The sideways strip under a point (a code block, a table, quick replies, photos), when it holds more than
    /// fits and so can scroll.
    static func sideScroller(at point: CGPoint, in view: UIView) -> UIScrollView? {
        var hit: UIView? = view.hitTest(point, with: nil)
        while let current = hit {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                return scroll
            }
            if current === view { break }
            hit = current.superview
        }
        return nil
    }

    /// A swipe that ended far enough to the right, or fast enough, to mean "back".
    static func wentBack(_ pan: UIPanGestureRecognizer, in view: UIView) -> Bool {
        pan.translation(in: view).x > 90 || pan.velocity(in: view).x > 500
    }
}
