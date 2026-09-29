import AppKit

/// Now-playing strip shown inside the expanded notch: cover, title/artist and transport buttons.
/// Pure AppKit, fixed frames, no timers/observers. The parent calls `update()` on every change.
final class PlayerView: NSView {
    static let size = NSSize(width: 360, height: 64)

    // MARK: - Cached symbol images

    private static func symbol(_ name: String, _ pointSize: CGFloat, _ weight: NSFont.Weight) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return base?.withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 1, height: 1))
    }

    private static let previousImage = symbol("backward.fill", 15, .semibold)
    private static let nextImage = symbol("forward.fill", 15, .semibold)
    private static let playImage = symbol("play.fill", 20, .semibold)
    private static let pauseImage = symbol("pause.fill", 20, .semibold)
    private static let noteImage = symbol("music.note", 24, .regular)

    private static let emptyTitle = "Spotify não está tocando"
    private static let disabledAlpha: CGFloat = 0.35

    // MARK: - Layout constants

    private static let coverSide: CGFloat = 64
    static let coverRadius: CGFloat = 10
    private static let textX: CGFloat = coverSide + 12

    // MARK: - State

    private let spotify: Spotify
    private let cover = NSView(frame: NSRect(x: 0, y: 0, width: coverSide, height: coverSide))
    private let placeholder = NSImageView(frame: NSRect(x: 0, y: 0, width: coverSide, height: coverSide))
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let previousButton = TapButton(frame: .zero)
    private let playPauseButton = TapButton(frame: .zero)
    private let nextButton = TapButton(frame: .zero)

    // Last applied state (avoids redundant work in update()).
    private var hasApplied = false
    private var appliedNowPlaying: NowPlaying?
    private var appliedArtwork: CGImage?

    // MARK: - Init

    init(spotify: Spotify) {
        self.spotify = spotify
        super.init(frame: NSRect(origin: .zero, size: PlayerView.size))
        wantsLayer = true

        setupCover()
        setupLabels()
        setupButtons()

        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupCover() {
        cover.wantsLayer = true
        if let layer = cover.layer {
            layer.cornerRadius = PlayerView.coverRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.contentsGravity = .resizeAspectFill
            layer.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
            layer.borderWidth = 0.5
            layer.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
            layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }

        placeholder.image = PlayerView.noteImage
        placeholder.imageScaling = .scaleNone
        placeholder.imageAlignment = .alignCenter
        placeholder.contentTintColor = NSColor(white: 0.5, alpha: 1)
        cover.addSubview(placeholder)
        addSubview(cover)
    }

    private func setupLabels() {
        // Title/artist share the button row's center line (the play/pause button sits right under them).
        let width = PlayerView.size.width - PlayerView.textX

        configure(titleLabel,
                  font: .systemFont(ofSize: 14, weight: .semibold),
                  color: .white,
                  frame: NSRect(x: PlayerView.textX, y: 45, width: width, height: 18))
        configure(artistLabel,
                  font: .systemFont(ofSize: 12, weight: .medium),
                  color: NSColor(white: 1, alpha: 0.55),
                  frame: NSRect(x: PlayerView.textX, y: 30, width: width, height: 15))

        addSubview(titleLabel)
        addSubview(artistLabel)
    }

    private func configure(_ label: NSTextField, font: NSFont, color: NSColor, frame: NSRect) {
        label.frame = frame
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.allowsDefaultTighteningForTruncation = false
        label.isSelectable = false
    }

    private func setupButtons() {
        // Three buttons centered horizontally in the text column (play/pause exactly under the labels).
        let widths: [CGFloat] = [36, 40, 36]
        let gap: CGFloat = 12
        let height: CGFloat = 28
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var x = PlayerView.textX + ((PlayerView.size.width - PlayerView.textX) - total) / 2
        x = x.rounded()

        let buttons = [previousButton, playPauseButton, nextButton]
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + gap
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.focusRingType = .none
            button.contentTintColor = .white
            button.target = self
            addSubview(button)
        }

        previousButton.image = PlayerView.previousImage
        previousButton.action = #selector(previousTapped)
        previousButton.setAccessibilityLabel("Faixa anterior")

        playPauseButton.image = PlayerView.playImage
        playPauseButton.action = #selector(playPauseTapped)
        playPauseButton.setAccessibilityLabel("Reproduzir")

        nextButton.image = PlayerView.nextImage
        nextButton.action = #selector(nextTapped)
        nextButton.setAccessibilityLabel("Próxima faixa")
    }

    // MARK: - Shared cover transition

    /// Cover rect in this view's coordinates (the parent flies a copy of the artwork to/from here).
    var coverFrame: NSRect { cover.frame }

    /// Hides the real cover while the parent's flying copy stands in for it.
    func setCoverVisible(_ visible: Bool) { cover.alphaValue = visible ? 1 : 0 }

    // MARK: - Actions

    @objc private func previousTapped() { spotify.previousTrack() }
    @objc private func playPauseTapped() { spotify.playPause() }
    @objc private func nextTapped() { spotify.nextTrack() }

    // MARK: - Update

    /// Reads the Spotify state and touches only what changed since the last call.
    func update() {
        let np = spotify.nowPlaying
        let art = spotify.artwork

        if !hasApplied || np != appliedNowPlaying {
            applyNowPlaying(np, previous: hasApplied ? appliedNowPlaying : nil, first: !hasApplied)
            appliedNowPlaying = np
        }

        if !hasApplied || art !== appliedArtwork {
            applyArtwork(art)
            appliedArtwork = art
        }

        hasApplied = true
    }

    private func applyNowPlaying(_ np: NowPlaying?, previous: NowPlaying?, first: Bool) {
        let title = np?.title ?? PlayerView.emptyTitle
        let artist = np?.artist ?? ""
        if first || title != (previous?.title ?? PlayerView.emptyTitle) {
            if !first && !isHidden { TrackTransition.roll(titleLabel, duration: 0.42, backwards: spotify.lastChangeWentBack) }
            titleLabel.stringValue = title
        }
        if first || artist != (previous?.artist ?? "") {
            if !first && !isHidden { TrackTransition.roll(artistLabel, duration: 0.52, backwards: spotify.lastChangeWentBack) }
            artistLabel.stringValue = artist
        }

        let enabled = np != nil
        let wasEnabled = previous != nil
        if first || enabled != wasEnabled {
            let alpha: CGFloat = enabled ? 1 : PlayerView.disabledAlpha
            for button in [previousButton, playPauseButton, nextButton] {
                button.isEnabled = enabled
                button.restingAlpha = alpha
            }
        }

        let playing = np?.isPlaying ?? false
        if first || playing != (previous?.isPlaying ?? false) {
            playPauseButton.image = playing ? PlayerView.pauseImage : PlayerView.playImage
            playPauseButton.setAccessibilityLabel(playing ? "Pausar" : "Reproduzir")
        }
    }

    private func applyArtwork(_ art: CGImage?) {
        // Backing layers of layer-backed views already have implicit animations disabled;
        // the transaction makes that explicit and cheap.
        let oldContents = cover.layer?.contents, oldBackground = cover.layer?.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.layer?.contents = art
        CATransaction.commit()
        placeholder.isHidden = art != nil
        if hasApplied, !isHidden, window != nil, let layer = cover.layer {
            TrackTransition.flipCover(layer, from: oldContents, oldBackground: oldBackground,
                                      backwards: spotify.lastChangeWentBack)
        }
    }

    // MARK: - Backing scale

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            cover.layer?.contentsScale = scale
        }
    }
}

// MARK: - Button

/// Borderless image button that reacts to the first click even when the panel is not key,
/// with a soft capsule highlight on hover and a subtle dim while pressed.
private final class TapButton: NSButton {
    /// Alpha when idle (1 enabled, dimmed when disabled).
    var restingAlpha: CGFloat = 1 {
        didSet { alphaValue = restingAlpha }
    }

    /// Standalone sublayer (keeps implicit animations, unlike the view's backing layer).
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
        super.mouseDown(with: event)   // runs the tracking loop until mouse up
        alphaValue = restingAlpha
    }

    private func setHighlighted(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.12 : 0.2)
        highlight.opacity = on ? 1 : 0
        CATransaction.commit()
    }
}
