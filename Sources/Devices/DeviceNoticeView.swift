import AppKit

final class DeviceNoticeView: NSView {
    static let height: CGFloat = 44

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pool = (0..<3).map { _ in BatteryRing() }
    private var rings: [BatteryRing] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.55)
        for label in [titleLabel, detailLabel] {
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            label.wantsLayer = true
            addSubview(label)
        }
        for ring in pool {
            ring.isHidden = true
            addSubview(ring)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ event: DeviceMonitor.Event) {
        var parts: [(BatteryRing.Center, BatteryPart, Int)] = []
        switch event {
        case .connected(let accessory):
            setIcon(DeviceNoticeView.symbol(for: accessory))
            titleLabel.stringValue = accessory.name
            detailLabel.stringValue = "Connected"
            let warn = accessory.lowWarnLevel
            if let left = accessory.left { parts.append((.text("L"), left, warn)) }
            if let right = accessory.right { parts.append((.text("R"), right, warn)) }
            if let single = accessory.single { parts.append((.none, single, warn)) }
            if let batteryCase = accessory.batteryCase { parts.append((.symbol("rectangle.portrait.fill"), batteryCase, warn)) }
        case .lowBattery(let accessory):
            setIcon(DeviceNoticeView.symbol(for: accessory))
            titleLabel.stringValue = accessory.name
            detailLabel.stringValue = "Low battery"
            parts.append((.none, BatteryPart(level: accessory.lowestLevel ?? 0, charging: false), 100))
        case .charging(let mac):
            setIcon("laptopcomputer")
            titleLabel.stringValue = "Charging"
            detailLabel.stringValue = "\(mac.level)% · MacBook"
            parts.append((.symbol("bolt.fill"), BatteryPart(level: mac.level, charging: true), 0))
        }
        parts = Array(parts.prefix(pool.count))
        for (i, ring) in pool.enumerated() {
            ring.isHidden = i >= parts.count
            if i < parts.count { ring.configure(center: parts[i].0, part: parts[i].1, warnLevel: parts[i].2) }
        }
        rings = Array(pool.prefix(parts.count))
        layoutContent()
        animateIn()
    }

    private func setIcon(_ symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil))?
            .withSymbolConfiguration(config)
    }

    private func layoutContent() {
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: (h - 30) / 2, width: 30, height: 30)
        var x = bounds.width
        for ring in rings.reversed() {
            x -= BatteryRing.size.width
            ring.frame = NSRect(x: x, y: (h - BatteryRing.size.height) / 2,
                                width: BatteryRing.size.width, height: BatteryRing.size.height)
            x -= 6
        }
        let textX: CGFloat = 42
        let textWidth = max(0, x - textX - 6)
        titleLabel.frame = NSRect(x: textX, y: h / 2, width: textWidth, height: 17)
        detailLabel.frame = NSRect(x: textX, y: h / 2 - 16, width: textWidth, height: 14)
    }

    private func animateIn() {
        let now = CACurrentMediaTime()
        if let layer = icon.layer {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.5
            pop.toValue = 1
            pop.stiffness = 300
            pop.damping = 15
            pop.duration = pop.settlingDuration
            pop.beginTime = now + 0.08
            pop.fillMode = .backwards
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
            layer.add(pop, forKey: "pop")
        }
        for (i, ring) in rings.enumerated() { ring.fill(delay: 0.15 + Double(i) * 0.08) }
    }

    private static func symbol(for accessory: Accessory) -> String {
        if let model = AirPodsModel(productID: accessory.productID) { return model.symbol }
        switch accessory.kind {
        case .earbuds: return "earbuds"
        case .headphones: return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "magicmouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gamepad: return "gamecontroller"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

private final class BatteryRing: NSView {
    enum Center: Equatable { case none, text(String), symbol(String) }

    static let size = NSSize(width: 30, height: 40)

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let percent = NSTextField(labelWithString: "")
    private let centerLabel = NSTextField(labelWithString: "")
    private let centerIcon = NSImageView()
    private var level: CGFloat = 0

    init() {
        super.init(frame: NSRect(origin: .zero, size: BatteryRing.size))
        wantsLayer = true
        let diameter: CGFloat = 24
        let center = ringCenter
        let path = CGMutablePath()
        path.addArc(center: center, radius: diameter / 2 - 1.5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, progress] {
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = 3
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = CGColor(gray: 1, alpha: 0.16)

        percent.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        percent.textColor = NSColor(white: 1, alpha: 0.7)
        percent.alignment = .center
        percent.frame = NSRect(x: 0, y: 0, width: BatteryRing.size.width, height: 11)
        addSubview(percent)

        centerLabel.font = .systemFont(ofSize: 9, weight: .bold)
        centerLabel.textColor = .white
        centerLabel.alignment = .center
        centerLabel.frame = NSRect(x: center.x - 8, y: center.y - 6, width: 16, height: 12)
        addSubview(centerLabel)

        centerIcon.contentTintColor = .white
        centerIcon.frame = NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        addSubview(centerIcon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var ringCenter: CGPoint { CGPoint(x: BatteryRing.size.width / 2, y: BatteryRing.size.height - 13) }

    func configure(center: Center, part: BatteryPart, warnLevel: Int) {
        level = CGFloat(min(100, max(0, part.level))) / 100
        let low = part.level <= warnLevel && !part.charging
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeColor = low ? NSColor.systemRed.cgColor : NSColor.systemGreen.cgColor
        progress.strokeEnd = level
        CATransaction.commit()
        percent.stringValue = "\(part.level)%"

        switch center {
        case .none:
            centerLabel.isHidden = true
            centerIcon.isHidden = true
        case .text(let text):
            centerLabel.stringValue = text
            centerLabel.isHidden = false
            centerIcon.isHidden = true
        case .symbol(let name):
            centerIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
            centerIcon.isHidden = false
            centerLabel.isHidden = true
        }
    }

    func fill(delay: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = level
        anim.duration = 0.7
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .backwards
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        progress.add(anim, forKey: "fill")
    }
}
