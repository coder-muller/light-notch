import AppKit

final class AccentPicker: NSStackView {
    var onSelect: ((Preferences.AccentSource) -> Void)?

    private var swatches: [(source: Preferences.AccentSource, view: Swatch)] = []

    init(selected: Preferences.AccentSource) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        let options: [(Preferences.AccentSource, String)] = [
            (.cover, "Album cover"), (.spotify, "Spotify green"), (.white, "White"),
        ]
        for (source, name) in options {
            let swatch = Swatch(source: source)
            swatch.toolTip = name
            swatch.setAccessibilityLabel(name)
            swatch.onClick = { [weak self] in self?.select(source) }
            swatches.append((source, swatch))
            addArrangedSubview(swatch)
        }
        setSelected(selected, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setCover(_ image: CGImage?) {
        swatches.first { $0.source == .cover }?.view.setCover(image)
    }

    func setSelected(_ source: Preferences.AccentSource, animated: Bool) {
        for swatch in swatches { swatch.view.setSelected(swatch.source == source, animated: animated) }
    }

    private func select(_ source: Preferences.AccentSource) {
        setSelected(source, animated: true)
        onSelect?(source)
    }
}

private final class Swatch: NSView {
    static let side: CGFloat = 22

    var onClick: (() -> Void)?

    private let fill = CALayer()
    private let conic = CAGradientLayer()
    private let ring = CALayer()

    init(source: Preferences.AccentSource) {
        super.init(frame: NSRect(x: 0, y: 0, width: Swatch.side + 8, height: Swatch.side + 8))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.bounds = CGRect(x: 0, y: 0, width: Swatch.side + 8, height: Swatch.side + 8)
        ring.position = center
        ring.cornerRadius = ring.bounds.width / 2
        ring.borderWidth = 2
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.opacity = 0
        ring.transform = CATransform3DMakeScale(0.8, 0.8, 1)
        layer?.addSublayer(ring)

        fill.bounds = CGRect(x: 0, y: 0, width: Swatch.side, height: Swatch.side)
        fill.position = center
        fill.cornerRadius = Swatch.side / 2
        fill.masksToBounds = true
        fill.borderWidth = 0.5
        fill.borderColor = CGColor(gray: 0, alpha: 0.15)
        fill.contentsGravity = .resizeAspectFill
        fill.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        switch source {
        case .cover:
            conic.type = .conic
            conic.startPoint = CGPoint(x: 0.5, y: 0.5)
            conic.endPoint = CGPoint(x: 0.5, y: 0)
            conic.colors = [NSColor.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
                            .systemPink].map(\.cgColor)
            conic.frame = fill.bounds
            fill.addSublayer(conic)
        case .spotify:
            fill.backgroundColor = Accent.fallback
        case .white:
            fill.backgroundColor = .white
        }
        layer?.addSublayer(fill)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Swatch.side + 8, height: Swatch.side + 8) }

    func setCover(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        fill.contents = image
        conic.opacity = image == nil ? 1 : 0
        CATransaction.commit()
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        setAccessibilityValue(selected)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.2))
        } else {
            CATransaction.setDisableActions(true)
        }
        ring.opacity = selected ? 1 : 0
        ring.transform = selected ? CATransform3DIdentity : CATransform3DMakeScale(0.8, 0.8, 1)
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { scaleFill(1.1) }
    override func mouseExited(with event: NSEvent) { scaleFill(1) }

    override func mouseDown(with event: NSEvent) { scaleFill(0.9) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        scaleFill(inside ? 1.1 : 1)
        if inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func scaleFill(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        fill.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }
}
