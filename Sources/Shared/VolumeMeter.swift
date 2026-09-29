import AppKit

final class VolumeMeter: NSView {
    private let gap: CGFloat
    private let iconSize: CGFloat
    private let barHeight: CGFloat
    private let images: [NSImage]
    private let icon = CALayer()
    private let symbol = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private var imageIndex = -1
    private var level: CGFloat = 0

    init(frame: NSRect, iconSize: CGFloat, barHeight: CGFloat, gap: CGFloat = 6) {
        self.gap = gap
        self.iconSize = iconSize
        self.barHeight = barHeight
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        images = ["speaker.slash.fill", "speaker.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
            .map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(size: NSSize(width: 1, height: 1)) }
        super.init(frame: frame)
        wantsLayer = true

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        symbol.contentsGravity = .left
        symbol.contentsScale = scale
        icon.backgroundColor = CGColor(gray: 1, alpha: 0.75)
        icon.mask = symbol
        layer?.addSublayer(icon)

        track.backgroundColor = CGColor(gray: 1, alpha: 0.16)
        track.masksToBounds = true
        track.cornerCurve = .continuous
        fill.backgroundColor = Accent.fallback
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.cornerCurve = .continuous
        track.addSublayer(fill)
        layer?.addSublayer(track)

        layoutMeter()
        setLevel(0, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMeter()
        setLevel(level, animated: false)
    }

    private var iconBoxWidth: CGFloat { images.map(\.size.width).max() ?? iconSize }

    private func layoutMeter() {
        let h = bounds.height
        let box = CGSize(width: iconBoxWidth, height: images.map(\.size.height).max() ?? iconSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = CGRect(x: 0, y: ((h - box.height) / 2).rounded(), width: box.width, height: box.height)
        symbol.frame = icon.bounds
        let x = box.width + gap
        track.frame = CGRect(x: x, y: ((h - barHeight) / 2).rounded(), width: max(0, bounds.width - x), height: barHeight)
        track.cornerRadius = barHeight / 2
        fill.cornerRadius = barHeight / 2
        fill.position = CGPoint(x: 0, y: barHeight / 2)
        CATransaction.commit()
    }

    func setLevel(_ level: CGFloat, animated: Bool) {
        let level = min(1, max(0, level))
        self.level = level
        let index = level <= 0 ? 0 : level < 0.34 ? 2 : level < 0.67 ? 3 : 4
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.bounds = CGRect(x: 0, y: 0, width: track.bounds.width * level, height: barHeight)
        if index != imageIndex {
            imageIndex = index
            symbol.contents = images[index]
        }
        CATransaction.commit()
    }

    static func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval = 0.18) {
        let from = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alphaValue = alpha
        CATransaction.commit()
        view.layer?.removeAnimation(forKey: "volumeFade")
        guard duration > 0 else { return }
        view.layer?.add(fadeAnimation(from: from, to: Float(alpha), duration: duration), forKey: "volumeFade")
    }

    static func fade(_ layers: [CALayer], to opacity: Float, duration: CFTimeInterval = 0.18) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = opacity
            layer.removeAnimation(forKey: "volumeFade")
            if duration > 0 { layer.add(fadeAnimation(from: from, to: opacity, duration: duration), forKey: "volumeFade") }
        }
        CATransaction.commit()
    }

    private static func fadeAnimation(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return anim
    }

    func setAccent(_ color: CGColor, animated: Bool) {
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.5) } else { CATransaction.setDisableActions(true) }
        fill.backgroundColor = color
        CATransaction.commit()
    }
}
