import AppKit

final class NotchPreview: NSView {
    static let height: CGFloat = 132

    private static let notchSize = CGSize(width: 208, height: 32)
    private static let barHeights: [CGFloat] = [12, 14, 11, 13]
    private static let barDurations: [CFTimeInterval] = [0.45, 0.6, 0.38, 0.52]
    private static let barPhases: [CFTimeInterval] = [0.0, 0.21, 0.11, 0.32]

    private let backdrop = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let notch = CALayer()
    private let cover = CALayer()
    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var barsVisible = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }

        backdrop.cornerRadius = 14
        backdrop.cornerCurve = .continuous
        backdrop.masksToBounds = true
        backdrop.colors = [CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.08, alpha: 1)]
        root.addSublayer(backdrop)

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 1.1, y: -0.2)
        backdrop.addSublayer(glow)

        notch.backgroundColor = .black
        notch.cornerRadius = 12
        notch.cornerCurve = .continuous
        notch.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        notch.anchorPoint = CGPoint(x: 0.5, y: 1)
        backdrop.addSublayer(notch)

        cover.cornerRadius = 5
        cover.cornerCurve = .continuous
        cover.masksToBounds = true
        cover.contentsGravity = .resizeAspectFill
        cover.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        notch.addSublayer(cover)

        for bar in bars {
            bar.cornerRadius = 1.5
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
            notch.addSublayer(bar)
        }
        startBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NotchPreview.height) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        glow.frame = backdrop.bounds
        let size = NotchPreview.notchSize
        notch.bounds = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height + 14))
        notch.position = CGPoint(x: bounds.midX, y: bounds.maxY + 14)
        cover.frame = CGRect(x: 10, y: (size.height - 18) / 2, width: 18, height: 18)
        var x = size.width - 10 - (4 * 3 + 3 * 2.5)
        for bar in bars {
            bar.position = CGPoint(x: x + 1.5, y: size.height / 2)
            x += 5.5
        }
        CATransaction.commit()
    }

    func update(accent: CGColor, cover image: CGImage?, equalizer: Preferences.Equalizer, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.4)
        } else {
            CATransaction.setDisableActions(true)
        }
        for bar in bars { bar.backgroundColor = accent }
        glow.colors = [accent.copy(alpha: 0.55) ?? accent, accent.copy(alpha: 0) ?? accent]
        cover.contents = image
        cover.backgroundColor = image == nil ? CGColor(gray: 0.25, alpha: 1) : nil
        let visible = equalizer != .hidden
        if visible != barsVisible {
            barsVisible = visible
            for bar in bars { bar.opacity = visible ? 1 : 0 }
        }
        CATransaction.commit()
    }

    func bounce() {
        let size = NotchPreview.notchSize
        let peak = CATransform3DMakeScale((size.width + 10) / size.width, (size.height + 6) / size.height, 1)
        let hop = CAKeyframeAnimation(keyPath: "transform")
        hop.values = [CATransform3DIdentity, peak, CATransform3DIdentity,
                      CATransform3DMakeScale(1 + (peak.m11 - 1) * 0.3, 1 + (peak.m22 - 1) * 0.3, 1),
                      CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        hop.keyTimes = [0, 0.24, 0.55, 0.76, 1]
        hop.duration = 0.45
        hop.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn)]
        notch.add(hop, forKey: "bounce")
    }

    private func startBars() {
        let now = CACurrentMediaTime()
        for (i, bar) in bars.enumerated() {
            let loop = CABasicAnimation(keyPath: "bounds.size.height")
            loop.fromValue = 3
            loop.toValue = NotchPreview.barHeights[i]
            loop.duration = NotchPreview.barDurations[i]
            loop.autoreverses = true
            loop.repeatCount = .infinity
            loop.beginTime = now + NotchPreview.barPhases[i]
            loop.fillMode = .backwards
            loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            loop.isRemovedOnCompletion = false
            bar.add(loop, forKey: "loop")
        }
    }
}
