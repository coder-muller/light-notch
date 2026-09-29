import AppKit

final class TapButton: NSButton {
    var restingAlpha: CGFloat = 1 {
        didSet { alphaValue = restingAlpha }
    }

    private let highlight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        highlight.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { setHighlighted(false) } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { if isEnabled { setHighlighted(true) } }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = restingAlpha * 0.55
        super.mouseDown(with: event)
        alphaValue = restingAlpha
    }

    private func setHighlighted(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.12 : 0.2)
        highlight.opacity = on ? 1 : 0
        CATransaction.commit()
    }
}
