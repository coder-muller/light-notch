import AppKit

final class SettingsWindowController: NSWindowController {
    let prefs = Preferences.shared
    private let grid = NSGridView()
    private var actions: [ControlAction] = []

    init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LightNotch Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        build()
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        window.contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        section("Appearance")
        popup("Accent color:", items: [("Album cover", "cover"), ("Spotify green", "spotify"), ("White", "white")],
              selected: prefs.accent.rawValue) { [weak self] in
            self?.prefs.accent = Preferences.AccentSource(rawValue: $0) ?? .cover
        }
        popup("Equalizer:", items: [("Follow the music", "live"), ("Animation only", "animated"), ("Hidden", "hidden")],
              selected: prefs.equalizer.rawValue) { [weak self] in
            self?.prefs.equalizer = Preferences.Equalizer(rawValue: $0) ?? .live
        }
    }

    func section(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        if grid.numberOfRows > 1 { row.topPadding = 14 }
    }

    func popup(_ title: String, items: [(label: String, value: String)], selected: String,
               onChange: @escaping (String) -> Void) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for item in items {
            popup.addItem(withTitle: item.label)
            popup.lastItem?.representedObject = item.value
        }
        popup.selectItem(at: items.firstIndex { $0.value == selected } ?? 0)
        bind(popup) { control in
            if let value = (control as? NSPopUpButton)?.selectedItem?.representedObject as? String { onChange(value) }
        }
        grid.addRow(with: [NSTextField(labelWithString: title), popup])
    }

    @discardableResult
    func checkbox(_ title: String, on: Bool, onChange: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        bind(box) { control in onChange((control as? NSButton)?.state == .on) }
        grid.addRow(with: [NSGridCell.emptyContentView, box])
        return box
    }

    private func bind(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let action = ControlAction(handler)
        actions.append(action)
        control.target = action
        control.action = #selector(ControlAction.fire(_:))
    }
}

private final class ControlAction: NSObject {
    private let handler: (NSControl) -> Void

    init(_ handler: @escaping (NSControl) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ sender: NSControl) { handler(sender) }
}
