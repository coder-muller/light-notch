import AppKit

final class CoverView: NSView {
    var onClick: (() -> Void)?

    private let shade = CALayer()
    private let arrow = CALayer()

    func installHoverOverlay() {
        guard let layer else { return }
        shade.frame = layer.bounds
        shade.backgroundColor = CGColor(gray: 0, alpha: 0.4)
        shade.opacity = 0
        layer.addSublayer(shade)

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let size = image?.size ?? NSSize(width: 14, height: 14)
        let symbol = CALayer()
        symbol.contents = image
        symbol.contentsGravity = .resizeAspect
        symbol.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        symbol.frame = CGRect(origin: .zero, size: size)
        arrow.bounds = symbol.frame
        arrow.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        arrow.backgroundColor = .white
        arrow.mask = symbol
        arrow.opacity = 0
        arrow.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        layer.addSublayer(arrow)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setHover(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHover(false, animated: true) }

    override func viewDidHide() {
        super.viewDidHide()
        setHover(false, animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        arrow.transform = CATransform3DMakeScale(0.85, 0.85, 1)
    }

    override func mouseUp(with event: NSEvent) {
        setHover(bounds.contains(convert(event.locationInWindow, from: nil)), animated: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func setHover(_ on: Bool, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(on ? 0.2 : 0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        shade.opacity = on ? 1 : 0
        arrow.opacity = on ? 1 : 0
        arrow.transform = on ? CATransform3DIdentity : CATransform3DMakeScale(0.7, 0.7, 1)
        CATransaction.commit()
    }
}
