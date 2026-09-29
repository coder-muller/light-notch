import AppKit

final class DeviceNoticeView: NSView {
    static let height: CGFloat = 44

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ event: DeviceMonitor.Event) {
        rings.forEach { $0.removeFromSuperview() }
        rings.removeAll()

        switch event {
        case .connected(let accessory):
            setIcon(DeviceNoticeView.symbol(for: accessory))
            titleLabel.stringValue = accessory.name
            detailLabel.stringValue = "Connected"
            let warn = accessory.lowWarnLevel
            if let left = accessory.left { rings.append(BatteryRing(label: "L", part: left, warnLevel: warn)) }
            if let right = accessory.right { rings.append(BatteryRing(label: "R", part: right, warnLevel: warn)) }
            if let single = accessory.single { rings.append(BatteryRing(label: nil, part: single, warnLevel: warn)) }
            if let batteryCase = accessory.batteryCase {
                rings.append(BatteryRing(symbol: "rectangle.portrait.fill", part: batteryCase, warnLevel: warn))
            }
        case .lowBattery(let accessory):
            setIcon(DeviceNoticeView.symbol(for: accessory))
            titleLabel.stringValue = accessory.name
            detailLabel.stringValue = "Low battery"
            let level = accessory.lowestLevel ?? 0
            rings.append(BatteryRing(label: nil, part: BatteryPart(level: level, charging: false), warnLevel: 100))
        case .charging(let mac):
            setIcon("laptopcomputer")
            titleLabel.stringValue = "Charging"
            detailLabel.stringValue = "\(mac.level)% · MacBook"
            rings.append(BatteryRing(symbol: "bolt.fill", part: BatteryPart(level: mac.level, charging: true), warnLevel: 0))
        }
        rings.forEach { addSubview($0) }
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
    static let size = NSSize(width: 30, height: 40)

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let level: CGFloat
    private let percent = NSTextField(labelWithString: "")

    convenience init(label: String?, part: BatteryPart, warnLevel: Int) {
        self.init(part: part, warnLevel: warnLevel)
        if let label { addCenter(text: label) }
    }

    convenience init(symbol: String, part: BatteryPart, warnLevel: Int) {
        self.init(part: part, warnLevel: warnLevel)
        addCenter(symbol: symbol)
    }

    private init(part: BatteryPart, warnLevel: Int) {
        level = CGFloat(min(100, max(0, part.level))) / 100
        super.init(frame: NSRect(origin: .zero, size: BatteryRing.size))
        wantsLayer = true
        let diameter: CGFloat = 24
        let rect = CGRect(x: (BatteryRing.size.width - diameter) / 2, y: BatteryRing.size.height - diameter - 1,
                          width: diameter, height: diameter)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: diameter / 2 - 1.5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, progress] {
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = 3
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = CGColor(gray: 1, alpha: 0.16)
        let low = part.level <= warnLevel && !part.charging
        progress.strokeColor = low ? NSColor.systemRed.cgColor : NSColor.systemGreen.cgColor
        progress.strokeEnd = level

        percent.stringValue = "\(part.level)%"
        percent.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        percent.textColor = NSColor(white: 1, alpha: 0.7)
        percent.alignment = .center
        percent.frame = NSRect(x: 0, y: 0, width: BatteryRing.size.width, height: 11)
        addSubview(percent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var ringCenter: CGPoint { CGPoint(x: BatteryRing.size.width / 2, y: BatteryRing.size.height - 13) }

    private func addCenter(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        label.frame.origin = CGPoint(x: ringCenter.x - label.frame.width / 2, y: ringCenter.y - label.frame.height / 2)
        addSubview(label)
    }

    private func addCenter(symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        view.contentTintColor = .white
        view.frame = NSRect(x: ringCenter.x - 6, y: ringCenter.y - 6, width: 12, height: 12)
        addSubview(view)
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
