import AppKit

struct SettingsSection {
    let title: String
    let symbol: String
    let tint: NSColor
    var badge: String?
}

final class SettingsSidebar: NSVisualEffectView {
    static let width: CGFloat = 200

    var onSelect: ((Int) -> Void)?

    private var items: [SidebarItem] = []

    init(sections: [SettingsSection]) {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            let item = SidebarItem(section: section)
            item.onClick = { [weak self] in self?.select(index) }
            items.append(item)
            list.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        addSubview(list)

        let name = NSTextField(labelWithString: "LightNotch")
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let detail = NSTextField(labelWithString: version.isEmpty ? "Spotify in your notch" : "Version \(version)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [name, detail])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 1
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsSidebar.width),
            list.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ index: Int) {
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        onSelect?(index)
    }
}

private final class SidebarItem: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }

    init(section: SettingsSection) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = section.tint.cgColor
        tile.layer?.cornerRadius = 6
        tile.layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        tile.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [tile, label])
        row.spacing = 8
        row.alignment = .centerY
        if let badge = section.badge {
            let badgeLabel = NSTextField(labelWithString: badge)
            badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
            badgeLabel.textColor = .controlAccentColor
            row.addArrangedSubview(badgeLabel)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section.title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        let color: NSColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1)
            : hovering ? NSColor.labelColor.withAlphaComponent(0.05) : .clear
        layer?.backgroundColor = color.cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
