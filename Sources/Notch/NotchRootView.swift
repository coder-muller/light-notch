import AppKit

/// Root view: owns the black notch shape layer, reports clicks, and reports enter/exit through a
/// tracking area (no polling) so the expanded panel can close when the cursor leaves it.
final class NotchRootView: NSView {
    let shape = CALayer()
    /// Holds the notch content (player, wings), clipped to the black shape so nothing shows outside it
    /// while the shape animates. `clip` is its mask and must mirror every change made to `shape`.
    let content = PassthroughView()
    let clip = CALayer()
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for layer in [shape, clip] {
            layer.backgroundColor = NSColor.black.cgColor
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)   // grow downwards from the top-center
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // bottom corners only
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

    /// Visible black shape (model value). Hover and clicks only count inside it, not in the transparent
    /// room the window keeps around it for springs and the bounce.
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
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    // Clicks on the player's buttons are consumed by the buttons; anything else lands here.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that never takes clicks itself (they fall through to the root); its subviews still do.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
