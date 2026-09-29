import AppKit

/// "Nothing playing": a small note badge, two lines of text and a pill to open Spotify, centered as a row.
final class EmptyStateView: NSView {
    private static let green = NSColor(srgbRed: 29 / 255, green: 185 / 255, blue: 84 / 255, alpha: 1)

    private let badge = NSView()
    private let text = NSView()
    private let openButton = PillButton(title: "Abrir Spotify")

    /// Elements in reveal order.
    var pieces: [NSView] { Spotify.appURL == nil ? [badge, text] : [badge, text, openButton] }


    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Badge: soft circle with a green note.
        let side: CGFloat = 40
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        badge.layer?.cornerRadius = side / 2
        let note = NSImageView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        note.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        note.imageScaling = .scaleNone
        note.contentTintColor = EmptyStateView.green
        badge.addSubview(note)

        // Two left-aligned lines.
        let title = label("Nada tocando", .systemFont(ofSize: 14, weight: .semibold), .white)
        let subtitle = label("Dê play no Spotify",
                             .systemFont(ofSize: 12, weight: .medium), NSColor(white: 1, alpha: 0.5))
        let textWidth = max(title.frame.width, subtitle.frame.width)
        let lineGap: CGFloat = 2
        let textHeight = title.frame.height + lineGap + subtitle.frame.height
        text.wantsLayer = true
        text.frame.size = NSSize(width: textWidth, height: textHeight)
        subtitle.setFrameOrigin(.zero)
        title.setFrameOrigin(NSPoint(x: 0, y: subtitle.frame.height + lineGap))
        text.addSubview(title)
        text.addSubview(subtitle)

        openButton.target = self
        openButton.action = #selector(openSpotify)
        let showButton = Spotify.appURL != nil

        // Row: badge, 12 pt, text, 18 pt, button; centered in the view.
        let gap: CGFloat = 12, buttonGap: CGFloat = 18
        var width = side + gap + textWidth
        if showButton { width += buttonGap + openButton.frame.width }
        var x = ((frame.width - width) / 2).rounded()
        let midY = (frame.height / 2).rounded()
        badge.frame = NSRect(x: x, y: midY - side / 2, width: side, height: side)
        x += side + gap
        text.setFrameOrigin(NSPoint(x: x, y: (midY - textHeight / 2).rounded()))
        x += textWidth + buttonGap
        openButton.setFrameOrigin(NSPoint(x: x, y: (midY - openButton.frame.height / 2).rounded()))

        addSubview(badge)
        addSubview(text)
        if showButton { addSubview(openButton) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func label(_ string: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.sizeToFit()
        return label
    }

    @objc private func openSpotify() { Spotify.open() }
}

/// Capsule text button with a hover tint; reacts to the first click on the non-key panel.
final class PillButton: NSButton {
    private static let rest = NSColor(white: 1, alpha: 0.1).cgColor
    private static let hover = NSColor(white: 1, alpha: 0.18).cgColor

    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textWidth = attributedTitle.size().width
        frame.size = NSSize(width: (textWidth + 28).rounded(), height: 28)
        layer?.backgroundColor = PillButton.rest
        layer?.cornerRadius = 14
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { tint(PillButton.hover) }
    override func mouseExited(with event: NSEvent) { tint(PillButton.rest) }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.6
        super.mouseDown(with: event)
        alphaValue = 1
    }

    private func tint(_ color: CGColor) {
        guard let layer else { return }
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        anim.toValue = color
        anim.duration = 0.15
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        layer.add(anim, forKey: "tint")
        CATransaction.commit()
    }
}
