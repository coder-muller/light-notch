import AppKit

final class NotchRootView: NSView {
    let shape = CALayer()
    let content = PassthroughView()
    let clip = CALayer()
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for layer in [shape, clip] {
            layer.backgroundColor = NSColor.black.cgColor
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            layer.cornerCurve = .continuous
        }
        shape.zPosition = -1
        layer?.insertSublayer(shape, at: 0)

        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.mask = clip
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hoverRect = NSRect.zero {
        didSet { if hoverRect != oldValue { updateTrackingAreas() } }
    }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hoverRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
