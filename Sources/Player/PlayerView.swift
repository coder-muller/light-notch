import AppKit

/// Now-playing strip shown inside the expanded notch: cover, title/artist and transport buttons,
/// or a minimal empty state when nothing plays. Switching between the two is animated.
/// Pure AppKit, fixed frames, no timers/observers. The parent calls `update()` on every change.
final class PlayerView: NSView {
    static let size = NSSize(width: 360, height: rowHeight + ProgressBar.height)
    /// Cover / text / buttons row, above the progress bar.
    private static let rowHeight: CGFloat = 64
    private static let rowY = ProgressBar.height

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


    // MARK: - Layout constants

    private static let coverSide: CGFloat = 64
    static let coverRadius: CGFloat = 10
    private static let textX: CGFloat = coverSide + 12

    // MARK: - State

    private let spotify: Spotify
    /// Holds the now-playing elements; faded out as a whole when the empty state takes over.
    private let content = NSView(frame: NSRect(origin: .zero, size: PlayerView.size))
    private let empty = EmptyStateView(frame: NSRect(origin: .zero, size: PlayerView.size))
    private var showingEmpty = false
    private let cover = CoverView(frame: NSRect(x: 0, y: rowY, width: coverSide, height: coverSide))
    private let placeholder = NSImageView(frame: NSRect(x: 0, y: 0, width: coverSide, height: coverSide))
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let previousButton = TapButton(frame: .zero)
    private let playPauseButton = TapButton(frame: .zero)
    private let nextButton = TapButton(frame: .zero)
    private let shuffleButton = ModeButton(kind: .shuffle)
    private let repeatButton = ModeButton(kind: .repeating)
    private let progress = ProgressBar(frame: NSRect(x: 0, y: 0, width: PlayerView.size.width, height: ProgressBar.height))

    // Last applied state (avoids redundant work in update()).
    private var hasApplied = false
    private var appliedNowPlaying: NowPlaying?
    private var appliedArtwork: CGImage?

    // MARK: - Init

    init(spotify: Spotify) {
        self.spotify = spotify
        super.init(frame: NSRect(origin: .zero, size: PlayerView.size))
        wantsLayer = true
        content.wantsLayer = true
        addSubview(content)
        addSubview(empty)

        setupCover()
        setupLabels()
        setupButtons()
        progress.onSeek = { [weak self] seconds in self?.spotify.seek(to: seconds) }
        content.addSubview(progress)

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
        cover.installHoverOverlay()
        cover.onClick = { Spotify.open() }
        cover.setAccessibilityLabel("Abrir o Spotify")
        content.addSubview(cover)
    }

    private func setupLabels() {
        // Title/artist share the button row's center line (the play/pause button sits right under them).
        let width = PlayerView.size.width - PlayerView.textX

        configure(titleLabel,
                  font: .systemFont(ofSize: 14, weight: .semibold),
                  color: .white,
                  frame: NSRect(x: PlayerView.textX, y: PlayerView.rowY + 45, width: width, height: 18))
        configure(artistLabel,
                  font: .systemFont(ofSize: 12, weight: .medium),
                  color: NSColor(white: 1, alpha: 0.55),
                  frame: NSRect(x: PlayerView.textX, y: PlayerView.rowY + 30, width: width, height: 15))

        content.addSubview(titleLabel)
        content.addSubview(artistLabel)
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
        // Transport buttons centered horizontally in the text column (play/pause exactly under the labels),
        // with shuffle and repeat at the outer ends of the row.
        let widths: [CGFloat] = [36, 40, 36]
        let gap: CGFloat = 12
        let modeGap: CGFloat = 14
        let height: CGFloat = 28
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var x = PlayerView.textX + ((PlayerView.size.width - PlayerView.textX) - total) / 2
        x = x.rounded()

        let modeWidth = ModeButton.size.width
        shuffleButton.setFrameOrigin(NSPoint(x: x - modeGap - modeWidth, y: PlayerView.rowY))
        repeatButton.setFrameOrigin(NSPoint(x: x + total + modeGap, y: PlayerView.rowY))
        shuffleButton.onToggle = { [weak self] in
            guard let self else { return }
            self.spotify.setShuffling(!self.shuffleButton.isOn)
        }
        repeatButton.onToggle = { [weak self] in
            guard let self else { return }
            self.spotify.setRepeating(!self.repeatButton.isOn)
        }
        content.addSubview(shuffleButton)
        content.addSubview(repeatButton)

        let buttons = [previousButton, playPauseButton, nextButton]
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: PlayerView.rowY, width: width, height: height)
            x += width + gap
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.focusRingType = .none
            button.contentTintColor = .white
            button.target = self
            content.addSubview(button)
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
    var coverFrame: NSRect { cover.convert(cover.bounds, to: self) }

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
        let visible = hasApplied && !isHidden && window != nil
        // Track-change motion only makes sense while the song was already on screen.
        let wasShowingSong = hasApplied && !showingEmpty

        if !hasApplied || np != appliedNowPlaying {
            applyNowPlaying(np, previous: appliedNowPlaying, animate: visible && wasShowingSong && np != nil)
            appliedNowPlaying = np
        }

        if !hasApplied || art !== appliedArtwork {
            // Nothing playing: keep the last cover so it fades out with the rest.
            if np != nil || !hasApplied {
                applyArtwork(art, animate: visible && wasShowingSong)
                let accent = Accent.color(for: art)
                progress.setColor(accent, animated: visible && wasShowingSong)
                shuffleButton.setAccent(accent, animated: visible && wasShowingSong)
                repeatButton.setAccent(accent, animated: visible && wasShowingSong)
            }
            appliedArtwork = art
        }

        // Nothing playing: the bar keeps its last state and fades out with the rest.
        if np != nil {
            progress.setTiming(spotify.timing, animated: visible && wasShowingSong)
            shuffleButton.setOn(spotify.shuffling ?? false, animated: visible && wasShowingSong)
            repeatButton.setOn(spotify.repeating ?? false, animated: visible && wasShowingSong)
        }

        setShowingEmpty(np == nil, animated: visible)
        hasApplied = true
    }

    // MARK: - Empty <-> song

    private func setShowingEmpty(_ isEmpty: Bool, animated: Bool) {
        guard isEmpty != showingEmpty || !hasApplied else { return }
        showingEmpty = isEmpty
        let (outgoing, incoming): (NSView, NSView) = isEmpty ? (content, empty) : (empty, content)
        let pieces: [NSView] = isEmpty
            ? empty.pieces
            : [cover, titleLabel, artistLabel, shuffleButton, previousButton, playPauseButton, nextButton,
               repeatButton, progress]

        incoming.isHidden = false
        guard animated else {
            Motion.set(outgoing, alpha: 0)
            Motion.set(incoming, alpha: 1)
            outgoing.isHidden = true
            return
        }
        Motion.conceal(outgoing) { [weak self] in
            // Only if the state did not flip back meanwhile.
            guard let self, self.showingEmpty == isEmpty else { return }
            outgoing.isHidden = true
        }
        Motion.set(incoming, alpha: 1)
        Motion.reveal(pieces, delay: 0.1)
    }

    private func applyNowPlaying(_ np: NowPlaying?, previous: NowPlaying?, animate: Bool) {
        for button in [previousButton, playPauseButton, nextButton] { button.isEnabled = np != nil }
        // Nothing playing: the song content fades out as it was (the empty state covers it).
        guard let np else { return }

        if np.title != titleLabel.stringValue {
            if animate { TrackTransition.roll(titleLabel, duration: 0.42, backwards: spotify.lastChangeWentBack) }
            titleLabel.stringValue = np.title
        }
        if np.artist != artistLabel.stringValue {
            if animate { TrackTransition.roll(artistLabel, duration: 0.52, backwards: spotify.lastChangeWentBack) }
            artistLabel.stringValue = np.artist
        }

        let playing = np.isPlaying
        if previous == nil || playing != previous?.isPlaying {
            playPauseButton.image = playing ? PlayerView.pauseImage : PlayerView.playImage
            playPauseButton.setAccessibilityLabel(playing ? "Pausar" : "Reproduzir")
        }
    }

    private func applyArtwork(_ art: CGImage?, animate: Bool) {
        // Backing layers of layer-backed views already have implicit animations disabled;
        // the transaction makes that explicit and cheap.
        let oldContents = cover.layer?.contents, oldBackground = cover.layer?.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.layer?.contents = art
        CATransaction.commit()
        placeholder.isHidden = art != nil
        if animate, let layer = cover.layer {
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

// MARK: - Motion

/// Enter/leave animations for the empty <-> song switch (explicit layer animations; model values
/// are set directly so nothing snaps when the animations end).
private enum Motion {
    static func set(_ view: NSView, alpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAnimation(forKey: "conceal")
        view.alphaValue = alpha
        CATransaction.commit()
    }

    /// Quick fade while drifting up a few points.
    static func conceal(_ view: NSView, completion: @escaping () -> Void) {
        guard let layer = view.layer else { set(view, alpha: 0); completion(); return }
        let from = layer.presentation()?.opacity ?? Float(view.alphaValue)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = 0
        drift.toValue = 5
        let group = CAAnimationGroup()
        group.animations = [fade, drift]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        view.alphaValue = 0
        layer.add(group, forKey: "conceal")
        CATransaction.commit()
    }

    /// Pieces rise into place one after another with a soft spring, fading in.
    static func reveal(_ views: [NSView], delay: CFTimeInterval, stagger: CFTimeInterval = 0.045) {
        let now = CACurrentMediaTime()
        for (i, view) in views.enumerated() {
            guard let layer = view.layer else { continue }
            let begin = now + delay + Double(i) * stagger

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -10
            rise.toValue = 0
            rise.mass = 1
            rise.stiffness = 280
            rise.damping = 20
            rise.duration = rise.settlingDuration
            rise.beginTime = begin
            rise.fillMode = .backwards

            layer.add(fade, forKey: "revealFade")
            layer.add(rise, forKey: "revealRise")
        }
    }
}
