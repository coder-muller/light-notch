import AppKit
import ServiceManagement

final class SettingsWindowController: NSWindowController {
    private static let width: CGFloat = 460

    private let prefs = Preferences.shared
    private let artwork: () -> CGImage?
    private let preview = NotchPreview(frame: .zero)
    private lazy var accentPicker = AccentPicker(selected: prefs.accent)
    private var loginSwitch: NSSwitch?
    private var actions: [ControlAction] = []

    init(artwork: @escaping () -> CGImage?) {
        self.artwork = artwork
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.width, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LightNotch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 20, bottom: 22, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        build(into: stack)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: SettingsWindowController.width),
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = content
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        window.contentView = scroll
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        window.setContentSize(NSSize(width: SettingsWindowController.width,
                                     height: min(content.fittingSize.height, visible - 60)))

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPreview(animated: true)
        }
        refreshPreview(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        loginSwitch?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshPreview(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        refreshPreview(animated: true)
    }

    private func refreshPreview(animated: Bool) {
        let image = artwork()
        accentPicker.setCover(image)
        preview.update(accent: Accent.color(for: image), cover: image, equalizer: prefs.equalizer, animated: animated)
    }

    private func build(into stack: NSStackView) {
        stack.addArrangedSubview(preview)
        stack.setCustomSpacing(14, after: preview)

        let name = NSTextField(labelWithString: "LightNotch")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let tagline = NSTextField(labelWithString: "Spotify in your notch · Version \(version)")
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = .secondaryLabelColor
        let header = NSStackView(views: [name, tagline])
        header.orientation = .vertical
        header.spacing = 2
        header.alignment = .centerX
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(22, after: header)

        let login = toggle(on: SMAppService.mainApp.status == .enabled) { [weak self] in self?.setOpenAtLogin($0) }
        loginSwitch = login
        group("General", into: stack, rows: [
            row("power", "Open at login", "Start LightNotch when you log in", login),
        ])

        accentPicker.onSelect = { [weak self] in self?.prefs.accent = $0 }
        var equalizerControl: NSSegmentedControl?
        let equalizer = segmented(["Live", "Animated", "Off"], values: Preferences.Equalizer.allCases,
                                  selected: prefs.equalizer) { [weak self] choice in
            guard let self else { return }
            if choice == .live, self.prefs.equalizer != .live, let control = equalizerControl {
                self.confirmLiveEqualizer(control)
            } else {
                self.prefs.equalizer = choice
            }
        }
        equalizerControl = equalizer
        group("Appearance", into: stack, rows: [
            row("paintpalette", "Accent color", "Equalizer, bars and icons", accentPicker),
            row("waveform", "Equalizer", "Live follows the music you hear", equalizer),
        ])

        let volume = segmented(["Mac", "Spotify"], values: Preferences.VolumeSource.allCases,
                               selected: prefs.volumeSource) { [weak self] in self?.prefs.volumeSource = $0 }
        let duration = segmented(["Short", "Medium", "Long"], values: Preferences.Duration.allCases,
                                 selected: prefs.noticeDuration) { [weak self] in self?.prefs.noticeDuration = $0 }
        group("Behavior", into: stack, rows: [
            row("arrow.up.and.down", "Bounce on hover", "A small hop when the pointer arrives",
                toggle(on: prefs.hoverBounce) { [weak self] on in
                    self?.prefs.hoverBounce = on
                    if on { self?.preview.bounce() }
                }),
            row("music.note", "Track notice", "Show the new song when it changes",
                toggle(on: prefs.trackNotice) { [weak self] in self?.prefs.trackNotice = $0 }),
            row("speaker.wave.2", "Scroll for volume", "Scroll over the notch to change it",
                toggle(on: prefs.scrollVolume) { [weak self] in self?.prefs.scrollVolume = $0 }),
            row("slider.horizontal.3", "Volume", "Which volume scrolling changes", volume),
            row("pause", "Stay while paused", "Keep the cover and controls around",
                toggle(on: prefs.keepWhilePaused) { [weak self] in self?.prefs.keepWhilePaused = $0 }),
            row("cursorarrow.rays", "Open on hover", "Open the player without clicking",
                toggle(on: prefs.openOnHover) { [weak self] in self?.prefs.openOnHover = $0 }),
            row("timer", "Notice duration", "How long notices stay on screen", duration),
        ])

        group("Devices", badge: "BETA", into: stack, rows: [
            row("airpodspro", "Connected devices", "AirPods and headphones with their battery",
                toggle(on: prefs.deviceConnect) { [weak self] in self?.prefs.deviceConnect = $0 }),
            row("battery.25percent", "Low battery", "Warn when an accessory runs low",
                toggle(on: prefs.deviceLowBattery) { [weak self] in self?.prefs.deviceLowBattery = $0 }),
            row("powerplug", "Mac charging", "Show the battery when you plug in",
                toggle(on: prefs.macCharging) { [weak self] in self?.prefs.macCharging = $0 }),
        ])
    }

    private func group(_ title: String, badge: String? = nil, into stack: NSStackView, rows: [NSView]) {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let captionRow = NSStackView(views: [caption])
        captionRow.spacing = 6
        if let badge { captionRow.addArrangedSubview(BadgeView(text: badge)) }
        captionRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        stack.addArrangedSubview(captionRow)
        stack.setCustomSpacing(7, after: captionRow)

        let card = SettingsCard()
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        for (i, row) in rows.enumerated() {
            if i > 0 { column.addArrangedSubview(Separator()) }
            column.addArrangedSubview(row)
        }
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(card)
        stack.setCustomSpacing(20, after: card)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ control: NSView) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        return row
    }

    private func toggle(on: Bool, _ onChange: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.state = on ? .on : .off
        bind(control) { onChange(($0 as? NSSwitch)?.state == .on) }
        return control
    }

    private func segmented<T: Equatable>(_ labels: [String], values: [T], selected: T,
                                         _ onChange: @escaping (T) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        control.controlSize = .small
        control.selectedSegment = values.firstIndex(of: selected) ?? 0
        bind(control) { sender in
            guard let index = (sender as? NSSegmentedControl)?.selectedSegment, values.indices.contains(index) else { return }
            onChange(values[index])
        }
        return control
    }

    private func bind(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let action = ControlAction(handler)
        actions.append(action)
        control.target = action
        control.action = #selector(ControlAction.fire(_:))
    }

    private func confirmLiveEqualizer(_ control: NSSegmentedControl) {
        let previous = prefs.equalizer
        let alert = NSAlert()
        alert.messageText = "Follow the music live?"
        alert.informativeText = "The equalizer will listen to Spotify's audio and redraw about 30 times a second while music plays. That keeps a CPU core a little busy (around 3–4%) and uses more battery than the animation. macOS will also ask for audio recording access."
        alert.addButton(withTitle: "Use Live")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.prefs.equalizer = .live
            } else {
                control.selectedSegment = Preferences.Equalizer.allCases.firstIndex(of: previous) ?? 1
            }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("LightNotch: could not update the login item: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        loginSwitch?.state = service.status == .enabled ? .on : .off
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class BadgeView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

private final class SettingsCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? NSColor(white: 1, alpha: 0.05).cgColor : NSColor.white.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

private final class Separator: NSView {
    private let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        line.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = CGRect(x: 44, y: 0, width: max(0, bounds.width - 44), height: 0.5)
        CATransaction.commit()
    }
}

private final class ControlAction: NSObject {
    private let handler: (NSControl) -> Void

    init(_ handler: @escaping (NSControl) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ sender: NSControl) { handler(sender) }
}
