import AppKit

final class ProgressBar: NSView {
    static let height: CGFloat = 22

    var onSeek: ((Double) -> Void)?

    private static let thin: CGFloat = 4
    private static let thick: CGFloat = 6
    private static let barY: CGFloat = 7
    private static let inset: CGFloat = 44
    private static let labelGap: CGFloat = 8
    private static let glide: CFTimeInterval = 0.3

    private let track = CALayer()
    private let fill = CALayer()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")

    private var timing: PlaybackTiming?
    private var hovering = false
    private var scrubbing: CGFloat?
    private var clock: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        track.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        track.masksToBounds = true
        track.cornerCurve = .continuous
        fill.backgroundColor = Accent.fallback
        fill.anchorPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerCurve = .continuous
        track.addSublayer(fill)
        layer?.addSublayer(track)

        for (label, alignment) in [(elapsedLabel, NSTextAlignment.right), (totalLabel, .left)] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = NSColor(white: 1, alpha: 0.5)
            label.alignment = alignment
            label.isSelectable = false
            label.wantsLayer = true
            label.alphaValue = 0
            addSubview(label)
        }

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        layoutBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBar()
    }

    private func layoutBar() {
        let w = bounds.width
        let labelWidth = ProgressBar.inset - ProgressBar.labelGap
        let labelY = (ProgressBar.barY - 6.5).rounded()
        elapsedLabel.frame = NSRect(x: 0, y: labelY, width: labelWidth, height: 13)
        totalLabel.frame = NSRect(x: w - labelWidth, y: labelY, width: labelWidth, height: 13)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.position = CGPoint(x: w / 2, y: ProgressBar.barY)
        setThickness(hovering ? ProgressBar.thick : ProgressBar.thin)
        CATransaction.commit()
        syncFill(animated: false)
    }

    private func setThickness(_ h: CGFloat) {
        let w = bounds.width
        track.bounds = CGRect(x: 0, y: -h / 2, width: w, height: h)
        let narrow = h == ProgressBar.thick && w > 2 * ProgressBar.inset
        track.transform = narrow ? CATransform3DMakeScale((w - 2 * ProgressBar.inset) / w, 1, 1) : CATransform3DIdentity
        track.cornerRadius = h / 2
        fill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        fill.cornerRadius = h / 2
    }

    func setTiming(_ new: PlaybackTiming?, animated: Bool) {
        guard new != timing else { return }
        timing = new
        guard scrubbing == nil else { return }
        syncFill(animated: animated)
        if hovering { updateLabels() }
    }

    func setColor(_ color: CGColor, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.backgroundColor = color
        CATransaction.commit()
    }

    private func fraction(at time: CFTimeInterval) -> CGFloat {
        guard let timing, timing.duration > 0 else { return 0 }
        return CGFloat(timing.position(at: time) / timing.duration)
    }

    private func syncFill(animated: Bool) {
        let w = bounds.width
        let now = CACurrentMediaTime()
        let from = fill.presentation()?.position.x ?? fill.position.x
        let target = fraction(at: now) * w
        let jump = animated && abs(from - target) > 1.5

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAnimation(forKey: "glide")
        fill.removeAnimation(forKey: "progress")

        guard let timing, timing.duration > 0 else {
            fill.position = CGPoint(x: 0, y: 0)
            if jump { fill.add(glide(from: from, to: 0), forKey: "glide") }
            CATransaction.commit()
            return
        }

        let playing = timing.isPlaying && timing.position(at: now) < timing.duration
        if playing {
            fill.position = CGPoint(x: w, y: 0)
            let start = jump ? now + ProgressBar.glide : now
            let startX = fraction(at: start) * w
            if jump { fill.add(glide(from: from, to: startX), forKey: "glide") }
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = startX
            run.toValue = w
            run.beginTime = start
            run.duration = max(0.01, timing.duration - timing.position(at: start))
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            fill.add(run, forKey: "progress")
        } else {
            fill.position = CGPoint(x: target, y: 0)
            if jump { fill.add(glide(from: from, to: target), forKey: "glide") }
        }
        CATransaction.commit()
    }

    private func glide(from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = ProgressBar.glide
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return anim
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let timing, timing.duration > 0 else { return }
        setHovering(true)
        scrub(to: event, animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrubbing != nil else { return }
        scrub(to: event, animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let fraction = scrubbing, let timing else { return }
        scrubbing = nil
        onSeek?(Double(fraction) * timing.duration)
        syncFill(animated: true)
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !inside { setHovering(false) }
    }

    private func scrub(to event: NSEvent, animated: Bool) {
        let w = bounds.width
        let x = convert(event.locationInWindow, from: nil).x
        let inset = hovering && w > 2 * ProgressBar.inset ? ProgressBar.inset : 0
        let fraction = min(max((x - inset) / max(w - 2 * inset, 1), 0), 1)
        scrubbing = fraction

        let from = fill.presentation()?.position.x ?? fill.position.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAnimation(forKey: "glide")
        fill.removeAnimation(forKey: "progress")
        fill.position = CGPoint(x: fraction * w, y: 0)
        if animated { fill.add(glide(from: from, to: fraction * w), forKey: "glide") }
        CATransaction.commit()
        updateLabels()
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { if scrubbing == nil { setHovering(false) } }

    override func viewDidHide() {
        super.viewDidHide()
        scrubbing = nil
        setHovering(false, animated: false)
    }

    private func setHovering(_ on: Bool, animated: Bool = true) {
        guard on != hovering else { return }
        hovering = on

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        setThickness(on ? ProgressBar.thick : ProgressBar.thin)
        CATransaction.commit()

        if on { updateLabels() }
        for label in [elapsedLabel, totalLabel] { fadeLabel(label, in: on, animated: animated) }

        clock?.invalidate()
        clock = nil
        if on {
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            clock.tolerance = 0.1
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
    }

    private func tick() {
        guard !isHiddenOrHasHiddenAncestor, window != nil else { return setHovering(false, animated: false) }
        updateLabels()
    }

    private func fadeLabel(_ label: NSTextField, in on: Bool, animated: Bool) {
        let from = label.layer?.presentation()?.opacity ?? Float(label.alphaValue)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.alphaValue = on ? 1 : 0
        CATransaction.commit()
        guard animated, let layer = label.layer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = on ? 1 : 0
        let offset: CGFloat = label === elapsedLabel ? -6 : 6
        let rise = CABasicAnimation(keyPath: "transform.translation.x")
        rise.fromValue = on ? offset : 0
        rise.toValue = on ? 0 : offset
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = on ? 0.22 : 0.15
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "hover")
    }

    private func updateLabels() {
        guard let timing else {
            elapsedLabel.stringValue = ""
            totalLabel.stringValue = ""
            return
        }
        let position = scrubbing.map { Double($0) * timing.duration } ?? timing.position(at: CACurrentMediaTime())
        elapsedLabel.stringValue = ProgressBar.format(position)
        totalLabel.stringValue = ProgressBar.format(timing.duration)
    }

    private static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
