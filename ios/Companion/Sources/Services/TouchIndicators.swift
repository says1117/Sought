import UIKit

// Demo recordings: `-showTouches YES` draws a soft circle wherever a finger (or a UI test) touches, so screen
// recordings show taps like a product video. Off in normal use. The recognizer never claims touches, so the app
// behaves exactly the same.

enum TouchIndicators {
    private static var installed = false

    @MainActor
    static func installIfRequested() {
        guard UserDefaults.standard.bool(forKey: "showTouches"), !installed else { return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); installIfRequested() }
            return
        }
        installed = true
        let overlay = PassthroughView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.layer.zPosition = 10_000
        window.addSubview(overlay)
        let r = TouchRecognizer(overlay: overlay)
        window.addGestureRecognizer(r)
    }
}

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var overlay: UIView?
    private var dots: [ObjectIdentifier: UIView] = [:]

    init(overlay: UIView) {
        self.overlay = overlay
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let overlay else { return }
        overlay.superview?.bringSubviewToFront(overlay)
        for t in touches {
            let d = UIView(frame: CGRect(x: 0, y: 0, width: 46, height: 46))
            d.layer.cornerRadius = 23
            d.backgroundColor = UIColor.white.withAlphaComponent(0.55)
            d.layer.borderColor = UIColor(red: 15 / 255, green: 30 / 255, blue: 36 / 255, alpha: 0.28).cgColor
            d.layer.borderWidth = 1.5
            d.layer.shadowColor = UIColor.black.cgColor
            d.layer.shadowOpacity = 0.18
            d.layer.shadowRadius = 6
            d.center = t.location(in: overlay)
            d.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            d.alpha = 0
            overlay.addSubview(d)
            UIView.animate(withDuration: 0.12) { d.transform = .identity; d.alpha = 1 }
            dots[ObjectIdentifier(t)] = d
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let overlay else { return }
        for t in touches { dots[ObjectIdentifier(t)]?.center = t.location(in: overlay) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            guard let d = dots.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            UIView.animate(withDuration: 0.3, animations: { d.alpha = 0; d.transform = CGAffineTransform(scaleX: 1.35, y: 1.35) },
                           completion: { _ in d.removeFromSuperview() })
        }
        if dots.isEmpty { state = .failed }   // reset quietly; never recognizes, never blocks other gestures
    }
}
