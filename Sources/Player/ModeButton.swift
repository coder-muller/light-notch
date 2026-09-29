import AppKit

final class ModeButton: NSView {
    enum Kind { case shuffle, repeating }

    static let size = NSSize(width: 28, height: 28)

    var onToggle: (() -> Void)?

    private static let offColor = CGColor(gray: 1, alpha: 0.45)
    private static let hoverColor = CGColor(gray: 1, alpha: 0.8)
    private static let dotSide: CGFloat = 4

    private let icon = CALayer()
    private let symbol = CALayer()
    private let dot = CALayer()

    private(set) var isOn = false
    private var accent = Accent.fallback
    private var hovering = false

    init(kind: Kind) {
        super.init(frame: NSRect(origin: .zero, size: ModeButton.size))
        wantsLayer = true
        layer?.masksToBounds = false

        let name = kind == .shuffle ? "shuffle" : "repeat"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let imageSize = image?.size ?? NSSize(width: 14, height: 12)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        symbol.contents = image
        symbol.contentsGravity = .resizeAspect
        symbol.contentsScale = scale
        symbol.frame = CGRect(origin: .zero, size: imageSize)

        icon.bounds = CGRect(origin: .zero, size: imageSize)
        icon.position = CGPoint(x: ModeButton.size.width / 2, y: ModeButton.size.height / 2 + 2)
        icon.backgroundColor = ModeButton.offColor
        icon.mask = symbol
        layer?.addSublayer(icon)

        dot.bounds = CGRect(x: 0, y: 0, width: ModeButton.dotSide, height: ModeButton.dotSide)
        dot.cornerRadius = ModeButton.dotSide / 2
        dot.position = CGPoint(x: ModeButton.size.width / 2, y: 3)
        dot.backgroundColor = accent
        dot.opacity = 0
        dot.transform = CATransform3DMakeScale(0.2, 0.2, 1)
        layer?.addSublayer(dot)

        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(kind == .shuffle ? "Shuffle" : "Repeat")
        setAccessibilityValue(false)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        setAccessibilityValue(on)
        applyColors(animated: animated)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.opacity = on ? 1 : 0
        dot.transform = on ? CATransform3DIdentity : CATransform3DMakeScale(0.2, 0.2, 1)
        CATransaction.commit()
        guard animated else { return }

        if on {
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2
            grow.toValue = 1
            grow.stiffness = 380
            grow.damping = 14
            grow.duration = grow.settlingDuration
            dot.add(grow, forKey: "scale")
        } else {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.2
            shrink.duration = 0.18
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dot.add(shrink, forKey: "scale")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0 : 1
        fade.toValue = on ? 1 : 0
        fade.duration = on ? 0.2 : 0.16
        dot.add(fade, forKey: "opacity")

        if on { playOnMotion() } else { playOffMotion() }
    }

    func setAccent(_ color: CGColor, animated: Bool) {
        accent = color
        applyColors(animated: animated)
    }

    private func applyColors(animated: Bool) {
        let iconColor = isOn ? accent : (hovering ? ModeButton.hoverColor : ModeButton.offColor)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        icon.backgroundColor = iconColor
        dot.backgroundColor = accent
        CATransaction.commit()
    }

    private func playOnMotion() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 0.78, 1.12, 1]
        pop.keyTimes = [0, 0.3, 0.65, 1]
        pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                               CAMediaTimingFunction(name: .easeInEaseOut),
                               CAMediaTimingFunction(name: .easeInEaseOut)]
        pop.duration = 0.36
        icon.add(pop, forKey: "motion")
    }

    private func playOffMotion() {
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.86, 1]
        dip.keyTimes = [0, 0.4, 1]
        dip.duration = 0.22
        dip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.add(dip, forKey: "motion")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.6
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        applyColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { symbol.contentsScale = scale }
    }
}
