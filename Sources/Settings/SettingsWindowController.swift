import AppKit
import ServiceManagement

final class SettingsWindowController: NSWindowController {
    private static let size = NSSize(width: 700, height: 500)
    private static let sections = [
        SettingsSection(title: "General", symbol: "gearshape.fill", tint: .systemGray),
        SettingsSection(title: "Appearance", symbol: "paintbrush.fill", tint: .systemPurple),
        SettingsSection(title: "Gestures", symbol: "hand.draw.fill", tint: .systemBlue),
        SettingsSection(title: "Notices", symbol: "bell.badge.fill", tint: .systemRed),
        SettingsSection(title: "Devices", symbol: "airpodspro", tint: .systemGreen, badge: "BETA"),
    ]

    private let prefs = Preferences.shared
    private let artwork: () -> CGImage?
    private let preview = NotchPreview(frame: .zero)
    private lazy var accentPicker = AccentPicker(selected: prefs.accent)
    private let sidebar = SettingsSidebar(sections: SettingsWindowController.sections)
    private let scroll = NSScrollView()
    private var panes: [NSView] = []
    private var current = -1
    private var loginSwitch: NSSwitch?
    private var actions: [ControlAction] = []

    init(artwork: @escaping () -> CGImage?) {
        self.artwork = artwork
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LightNotch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(sidebar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        window.setContentSize(SettingsWindowController.size)

        panes = [generalPane(), appearancePane(), gesturesPane(), noticesPane(), devicesPane()]
        sidebar.onSelect = { [weak self] in self?.showPane($0) }
        sidebar.select(0)

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

    private func showPane(_ index: Int) {
        guard index != current, panes.indices.contains(index) else { return }
        current = index
        let pane = panes[index]
        scroll.documentView = pane
        pane.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.contentView.scroll(to: .zero)

        guard let layer = pane.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 6
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(group, forKey: "appear")
    }

    // MARK: Panes

    private func generalPane() -> NSView {
        let login = toggle(on: SMAppService.mainApp.status == .enabled) { [weak self] in self?.setOpenAtLogin($0) }
        loginSwitch = login
        return pane("General") { stack in
            card(into: stack, rows: [
                row("power", "Open at login", "Start LightNotch when you log in", login),
                row("arrow.up.left.and.arrow.down.right", "Hide in full screen", "Only notices show over full-screen apps",
                    toggle(on: prefs.hideInFullScreen) { [weak self] in self?.prefs.hideInFullScreen = $0 }),
                row("pause", "Stay while paused", "Keep the cover and controls around",
                    toggle(on: prefs.keepWhilePaused) { [weak self] in self?.prefs.keepWhilePaused = $0 }),
                row("cursorarrow.rays", "Open on hover", "Open the player without clicking",
                    toggle(on: prefs.openOnHover) { [weak self] in self?.prefs.openOnHover = $0 }),
            ])
        }
    }

    private func appearancePane() -> NSView {
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
        return pane("Appearance") { stack in
            stack.addArrangedSubview(preview)
            stack.setCustomSpacing(18, after: preview)
            card(into: stack, rows: [
                row("paintpalette", "Accent color", "Equalizer, bars and icons", accentPicker),
                row("waveform", "Equalizer", "Live follows the music you hear", equalizer),
                row("arrow.up.and.down", "Bounce on hover", "A small hop when the pointer arrives",
                    toggle(on: prefs.hoverBounce) { [weak self] on in
                        self?.prefs.hoverBounce = on
                        if on { self?.preview.bounce() }
                    }),
            ])
        }
    }

    private func gesturesPane() -> NSView {
        let volume = segmented(["Mac", "Spotify"], values: Preferences.VolumeSource.allCases,
                               selected: prefs.volumeSource) { [weak self] in self?.prefs.volumeSource = $0 }
        return pane("Gestures") { stack in
            card(into: stack, rows: [
                row("speaker.wave.2", "Scroll for volume", "Scroll over the notch to change it",
                    toggle(on: prefs.scrollVolume) { [weak self] in self?.prefs.scrollVolume = $0 }),
                row("slider.horizontal.3", "Volume", "Which volume scrolling changes", volume),
            ])
            card(into: stack, rows: [
                row("hand.draw", "Swipe to change track", "Swipe sideways over the notch to skip",
                    toggle(on: prefs.swipeTracks) { [weak self] in self?.prefs.swipeTracks = $0 }),
            ])
        }
    }

    private func noticesPane() -> NSView {
        let duration = segmented(["Short", "Medium", "Long"], values: Preferences.Duration.allCases,
                                 selected: prefs.noticeDuration) { [weak self] in self?.prefs.noticeDuration = $0 }
        return pane("Notices") { stack in
            card(into: stack, rows: [
                row("music.note", "Track notice", "Show the new song when it changes",
                    toggle(on: prefs.trackNotice) { [weak self] in self?.prefs.trackNotice = $0 }),
                row("speaker.wave.3", "Show volume changes", "Volume keys and Control Center",
                    toggle(on: prefs.showVolumeChanges) { [weak self] in self?.prefs.showVolumeChanges = $0 }),
            ])
            card(into: stack, rows: [
                row("timer", "Notice duration", "How long notices stay on screen", duration),
            ])
        }
    }

    private func devicesPane() -> NSView {
        pane("Devices") { stack in
            card(into: stack, rows: [
                row("airpodspro", "Connected devices", "AirPods and headphones with their battery",
                    toggle(on: prefs.deviceConnect) { [weak self] in self?.prefs.deviceConnect = $0 }),
                row("battery.25percent", "Low battery", "Warn when an accessory runs low",
                    toggle(on: prefs.deviceLowBattery) { [weak self] in self?.prefs.deviceLowBattery = $0 }),
                row("powerplug", "Mac charging", "Show the battery when you plug in",
                    toggle(on: prefs.macCharging) { [weak self] in self?.prefs.macCharging = $0 }),
            ], footnote: "Beta: accessory batteries come from a macOS call that isn't public, so these notices may stop working after a system update.")
        }
    }

    // MARK: Building blocks

    private func pane(_ title: String, _ build: (NSStackView) -> Void) -> NSView {
        let document = FlippedView()
        document.wantsLayer = true
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(16, after: heading)
        build(stack)

        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        for view in stack.arrangedSubviews where view !== heading {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
        return document
    }

    private func card(into stack: NSStackView, rows: [NSView], footnote: String? = nil) {
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
        stack.setCustomSpacing(16, after: card)

        guard let footnote else { return }
        let note = NSTextField(wrappingLabelWithString: footnote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let holder = NSStackView(views: [note])
        holder.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.setCustomSpacing(8, after: card)
        stack.addArrangedSubview(holder)
        stack.setCustomSpacing(16, after: holder)
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
