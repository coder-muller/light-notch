import AppKit

/// Compact "Dynamic Island" state: the notch stretches sideways and shows a tiny cover on the left
/// wing and an animated mini equalizer on the right wing. The middle is left empty (physical notch).
///
/// Transparent view (the black background/size animation belong to the parent). Everything is plain
/// CALayers; the equalizer runs as repeating explicit animations on the render server, so the app
/// spends no CPU per frame (no timers, no display link).
final class CompactView: NSView {
    /// Width of each side wing (beyond the notch width).
    static let wingWidth: CGFloat = 40

    // MARK: - Layout constants

    private static let outerMargin: CGFloat = 12
    private static let maxCoverSide: CGFloat = 20
    static let coverRadius: CGFloat = 5

    private static let barCount = 4
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2.5
    private static let barMinHeight: CGFloat = 3
    /// Peak height of each bar (slightly different so the group looks organic).
    private static let barMaxHeights: [CGFloat] = [12, 14, 11, 13]
    private static let barDurations: [CFTimeInterval] = [0.45, 0.6, 0.38, 0.52]
    private static let barPhases: [CFTimeInterval] = [0.0, 0.21, 0.11, 0.32]
    private static let animationKey = "equalizer"

    /// Duration of the implicit smoothing between two live audio samples (~30 Hz feed).
    private static let levelSmoothing: CFTimeInterval = 0.08
    private static let placeholderColor = CGColor(gray: 0.18, alpha: 1)

    // MARK: - State

    private let spotify: Spotify
    private let coverLayer = CALayer()
    private let bars: [CALayer] = (0..<CompactView.barCount).map { _ in CALayer() }

    private var active = true
    private var playing = false
    private var animating = false
    /// True while real audio levels drive the bars (synthetic animation stays off).
    private var live = false
    /// Current model height of each bar (rest height unless live levels moved it).
    private var barHeights = [CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount)

    // Last applied state (avoids redundant work in update()).
    private var hasApplied = false
    private var appliedArtwork: CGImage?

    // MARK: - Init

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

    // MARK: - Layout

    /// Sets own size to (notch width + 2 wings, notch height) and positions the wing content.
    /// The frame origin is up to the parent.
    func layout(notchSize: CGSize) {
        let width = notchSize.width + 2 * CompactView.wingWidth
        let height = notchSize.height
        setFrameSize(NSSize(width: width, height: height))

        let scale = currentScale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Cover: square, vertically centered, 12 pt from the outer left edge.
        let side = max(0, min(CompactView.maxCoverSide, height - 12))
        coverLayer.frame = CGRect(x: CompactView.outerMargin, y: snap((height - side) / 2), width: side, height: side)

        // Equalizer: bars centered on the vertical midline, group ends 12 pt from the outer right edge.
        let groupWidth = CGFloat(CompactView.barCount) * CompactView.barWidth
            + CGFloat(CompactView.barCount - 1) * CompactView.barGap
        var x = width - CompactView.outerMargin - groupWidth
        let midY = snap(height / 2)
        for (i, bar) in bars.enumerated() {
            // Bounds height stays at the model value (rest height, or last live level);
            // running synthetic animations override it visually.
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: barHeights[i])
            bar.position = CGPoint(x: snap(x) + CompactView.barWidth / 2, y: midY)
            x += CompactView.barWidth + CompactView.barGap
        }

        CATransaction.commit()
    }

    // MARK: - Update

    /// Reads the Spotify state and touches only what changed since the last call.
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

            // Bar color: dominant vibrant color of the cover, computed once per cover change.
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

    /// Turns the bar animations on/off (parent passes false while the view is not visible).
    /// When turned on, they only run if something is playing.
    func setActive(_ active: Bool) {
        self.active = active
        syncAnimations()
    }

    // MARK: - Equalizer animations

    private func syncAnimations() {
        let shouldAnimate = active && playing
        if live {
            // Real levels drive the bars: never re-arm the synthetic animation.
            if animating { stopAnimations() }
            if !shouldAnimate { applyHeights([CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount), animated: true) }
            return
        }
        if shouldAnimate {
            // Also re-adds them if Core Animation dropped them (e.g. after a window detach).
            if !animating || bars.first?.animation(forKey: CompactView.animationKey) == nil {
                startAnimations()
            }
        } else if animating {
            stopAnimations()
        }
    }

    private func startAnimations() {
        animating = true
        for (i, bar) in bars.enumerated() {
            let anim = CABasicAnimation(keyPath: "bounds.size.height")
            anim.fromValue = CompactView.barMinHeight
            anim.toValue = CompactView.barMaxHeights[i]
            anim.duration = CompactView.barDurations[i]
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.timeOffset = CompactView.barPhases[i]
            anim.isRemovedOnCompletion = false
            bar.add(anim, forKey: CompactView.animationKey)
        }
    }

    private func stopAnimations() {
        animating = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.removeAllAnimations() }   // model value = minimum height
        CATransaction.commit()
    }

    // MARK: - Shared cover transition

    /// Cover rect in this view's coordinates (the parent flies a copy of the artwork to/from here).
    var coverFrame: NSRect { coverLayer.frame }

    /// Hides the real cover while the parent's flying copy stands in for it.
    func setCoverVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    // MARK: - Hover bounce

    /// Moves the cover left and the equalizer right by `dx` (and both down by `dy`) and back, using the
    /// parent's animation curve so they track the edges of the bouncing shape.
    func bounce(dx: CGFloat, dy: CGFloat, animation: (CATransform3D) -> CAAnimation) {
        coverLayer.add(animation(CATransform3DMakeTranslation(-dx, -dy, 0)), forKey: "bounce")
        let right = CATransform3DMakeTranslation(dx, -dy, 0)
        for bar in bars { bar.add(animation(right), forKey: "bounce") }
    }

    // MARK: - Live audio levels

    /// Níveis em tempo real, 4 bandas do grave (índice 0) ao agudo (3), cada uma 0...1.
    /// Primeira chamada desliga a animação sintética; as barras passam a seguir estes valores.
    func setLevels(_ levels: [Float]) {
        guard levels.count >= CompactView.barCount else { return }
        live = true
        if animating || bars.first?.animation(forKey: CompactView.animationKey) != nil { stopAnimations() }

        var targets = [CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount)
        if active && playing {
            for i in 0..<CompactView.barCount {
                let level = CGFloat(min(max(levels[i], 0), 1))
                // sqrt lifts low levels so quiet passages still move.
                targets[i] = CompactView.barMinHeight
                    + (CompactView.barMaxHeights[i] - CompactView.barMinHeight) * level.squareRoot()
            }
        }
        applyHeights(targets, animated: true)
    }

    /// Volta para a animação sintética (chamado quando o tap de áudio para/não está disponível).
    func useSyntheticAnimation() {
        guard live else { return }
        live = false
        // Return to the rest height first so the synthetic animation starts from a clean model.
        applyHeights([CGFloat](repeating: CompactView.barMinHeight, count: CompactView.barCount), animated: false)
        syncAnimations()
    }

    /// Sets bar heights (bounds keeps them vertically centered around `position`).
    /// Skips all work when no bar changes by a perceptible amount.
    private func applyHeights(_ targets: [CGFloat], animated: Bool) {
        var changed = false
        for i in 0..<CompactView.barCount where abs(targets[i] - barHeights[i]) >= 0.3 { changed = true; break }
        guard changed else { return }

        CATransaction.begin()
        if animated {
            // Short linear implicit animation smooths between ~30 Hz samples.
            CATransaction.setAnimationDuration(CompactView.levelSmoothing)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, bar) in bars.enumerated() {
            barHeights[i] = targets[i]
            bar.bounds = CGRect(x: 0, y: 0, width: CompactView.barWidth, height: targets[i])
        }
        CATransaction.commit()
    }

    // MARK: - System hooks

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
