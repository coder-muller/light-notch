import AppKit

final class CompactView: NSView {
    static let wingWidth: CGFloat = 40

    private static let outerMargin: CGFloat = 12
    private static let maxCoverSide: CGFloat = 20
    static let coverRadius: CGFloat = 5

    private static let barCount = 4
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2.5
    private static let barMinHeight: CGFloat = 3
    private static let barMaxHeights: [CGFloat] = [12, 14, 11, 13]
    private static let barDurations: [CFTimeInterval] = [0.45, 0.6, 0.38, 0.52]
    private static let barPhases: [CFTimeInterval] = [0.0, 0.21, 0.11, 0.32]
    private static let animationKey = "equalizer"

    private static let levelSmoothing: CFTimeInterval = 0.08
    private static let placeholderColor = CGColor(gray: 0.18, alpha: 1)

    private let spotify: Spotify
    private let coverLayer = CALayer()
    private let bars: [CALayer] = (0..<CompactView.barCount).map { _ in CALayer() }

    private var active = true
    private var playing = false
    private var animating = false
    private var live = false
    private var barHeights = [CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount)

    private var hasApplied = false
    private var appliedArtwork: CGImage?

    init(spotify: Spotify) {
        self.spotify = spotify
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        coverLayer.cornerRadius = CompactView.coverRadius
        coverLayer.cornerCurve = .continuous
        coverLayer.masksToBounds = true
        coverLayer.contentsGravity = .resizeAspectFill
        coverLayer.backgroundColor = CompactView.placeholderColor
        coverLayer.contentsScale = currentScale
        layer?.addSublayer(coverLayer)

        for bar in bars {
            bar.backgroundColor = Accent.fallback
            bar.cornerRadius = CompactView.barWidth / 2
            bar.cornerCurve = .continuous
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: CompactView.barMinHeight)
            layer?.addSublayer(bar)
        }

        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func layout(notchSize: CGSize) {
        let width = notchSize.width + 2 * CompactView.wingWidth
        let height = notchSize.height
        setFrameSize(NSSize(width: width, height: height))

        let scale = currentScale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let side = max(0, min(CompactView.maxCoverSide, height - 12))
        coverLayer.frame = CGRect(x: CompactView.outerMargin, y: snap((height - side) / 2), width: side, height: side)

        let groupWidth = CGFloat(CompactView.barCount) * CompactView.barWidth
            + CGFloat(CompactView.barCount - 1) * CompactView.barGap
        var x = width - CompactView.outerMargin - groupWidth
        let midY = snap(height / 2)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: barHeights[i])
            bar.position = CGPoint(x: snap(x) + CompactView.barWidth / 2, y: midY)
            x += CompactView.barWidth + CompactView.barGap
        }

        CATransaction.commit()
    }

    func update() {
        let art = spotify.artwork
        if !hasApplied || art !== appliedArtwork {
            let animate = hasApplied && !isHidden && window != nil
            let oldContents = coverLayer.contents, oldBackground = coverLayer.backgroundColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            coverLayer.contents = art
            coverLayer.backgroundColor = art == nil ? CompactView.placeholderColor : nil
            CATransaction.commit()

            let accent = Accent.color(for: art)
            if animate {
                let back = spotify.lastChangeWentBack
                TrackTransition.flipCover(coverLayer, from: oldContents, oldBackground: oldBackground, backwards: back)
                TrackTransition.colorWave(bars, to: accent, backwards: back)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for bar in bars { bar.backgroundColor = accent }
                CATransaction.commit()
            }
            appliedArtwork = art
        }

        playing = spotify.nowPlaying?.isPlaying ?? false
        hasApplied = true
        syncAnimations()
    }

    func setActive(_ active: Bool) {
        self.active = active
        syncAnimations()
    }

    private static let settleDuration: CFTimeInterval = 0.28
    private static let settleStagger: CFTimeInterval = 0.035
    private static let rest = [CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount)

    private func syncAnimations() {
        let shouldAnimate = active && playing
        if live {
            if animating { stopAnimations(settle: false) }
            if !shouldAnimate { applyHeights(CompactView.rest, duration: CompactView.settleDuration) }
            return
        }
        if shouldAnimate {
            if !animating || bars.first?.animation(forKey: CompactView.animationKey) == nil {
                startAnimations()
            }
        } else if animating {
            stopAnimations(settle: true)
        }
    }

    private func currentHeights() -> [CGFloat] {
        bars.map { $0.presentation()?.bounds.height ?? $0.bounds.height }
    }

    private func startAnimations() {
        animating = true
        let now = CACurrentMediaTime()
        let current = currentHeights()
        let lead: CFTimeInterval = 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            barHeights[i] = CompactView.barMinHeight
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: CompactView.barMinHeight)
            bar.removeAnimation(forKey: "settle")

            let loop = CABasicAnimation(keyPath: "bounds.size.height")
            loop.fromValue = CompactView.barMinHeight
            loop.toValue = CompactView.barMaxHeights[i]
            loop.duration = CompactView.barDurations[i]
            loop.autoreverses = true
            loop.repeatCount = .infinity
            loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            loop.beginTime = now + lead + CompactView.barPhases[i]
            loop.fillMode = .backwards
            loop.isRemovedOnCompletion = false
            bar.add(loop, forKey: CompactView.animationKey)

            if abs(current[i] - CompactView.barMinHeight) > 0.3 {
                bar.add(settle(from: current[i], delay: 0, duration: lead), forKey: "settle")
            }
        }
        CATransaction.commit()
    }

    private func stopAnimations(settle: Bool) {
        animating = false
        let current = currentHeights()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: CompactView.animationKey)
            let height = settle ? CompactView.barMinHeight : current[i]
            barHeights[i] = height
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: height)
            if settle, abs(current[i] - height) > 0.3 {
                bar.add(self.settle(from: current[i], delay: Double(i) * CompactView.settleStagger,
                                    duration: CompactView.settleDuration), forKey: "settle")
            }
        }
        CATransaction.commit()
    }

    private func settle(from height: CGFloat, delay: CFTimeInterval, duration: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "bounds.size.height")
        anim.fromValue = height
        anim.toValue = CompactView.barMinHeight
        anim.duration = duration
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .backwards
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return anim
    }

    var coverFrame: NSRect { coverLayer.frame }

    func setCoverVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    func bounce(dx: CGFloat, dy: CGFloat, animation: (CATransform3D) -> CAAnimation) {
        coverLayer.add(animation(CATransform3DMakeTranslation(-dx, -dy, 0)), forKey: "bounce")
        let right = CATransform3DMakeTranslation(dx, -dy, 0)
        for bar in bars { bar.add(animation(right), forKey: "bounce") }
    }

    func setLevels(_ levels: [Float]) {
        guard levels.count >= CompactView.barCount else { return }
        live = true
        if animating || bars.first?.animation(forKey: CompactView.animationKey) != nil { stopAnimations(settle: false) }

        var targets = [CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount)
        if active && playing {
            for i in 0..<CompactView.barCount {
                let level = CGFloat(min(max(levels[i], 0), 1))
                targets[i] = CompactView.barMinHeight
                    + (CompactView.barMaxHeights[i] - CompactView.barMinHeight) * level.squareRoot()
            }
        }
        applyHeights(targets, duration: CompactView.levelSmoothing, timing: .linear)
    }

    func useSyntheticAnimation() {
        guard live else { return }
        live = false
        if active && playing {
            syncAnimations()
        } else {
            applyHeights(CompactView.rest, duration: CompactView.settleDuration)
        }
    }

    private func applyHeights(_ targets: [CGFloat], duration: CFTimeInterval?,
                              timing: CAMediaTimingFunctionName = .easeOut) {
        var changed = false
        for i in 0..<CompactView.barCount where abs(targets[i] - barHeights[i]) >= 0.3 { changed = true; break }
        guard changed else { return }

        CATransaction.begin()
        if let duration {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, bar) in bars.enumerated() {
            barHeights[i] = targets[i]
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: targets[i])
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { syncAnimations() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            coverLayer.contentsScale = scale
        }
    }
}
