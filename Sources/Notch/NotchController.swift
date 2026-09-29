import AppKit

private enum Metrics {
    static let sidePadding: CGFloat = 20
    static let topGap: CGFloat = 8          // space between the notch band and the content
    static let bottomPadding: CGFloat = 16
    static let collapsedRadius: CGFloat = 10
    static let compactRadius: CGFloat = 12
    static let expandedRadius: CGFloat = 24
    static let springMargin: CGFloat = 8    // transparent room so the spring overshoot is not clipped
    static let bounceRoom: CGFloat = 4      // permanent room below the notch/wings for the hover bounce
    static let closeDelay: TimeInterval = 0.25   // after the cursor leaves the expanded panel
    static let virtualNotchWidth: CGFloat = 185
}

/// Borderless, non-activating panel that floats above the menu bar, on every Space and over full-screen apps.
/// Places the panel over the notch and drives a three-state machine:
/// `.notch` (idle), `.compact` (music playing: Dynamic Island-style side wings) and `.expanded`
/// (opened by a click on the notch/wings; closes when the cursor leaves it or on a click on empty space).
///
/// The window always matches the current state's shape (plus a small transparent margin for the spring),
/// so the tracking area only fires over the visible black shape and the rest of the menu bar stays clickable.
/// Growing swaps the window frame first and then animates; shrinking animates first and swaps the frame
/// when the animation ends. The shape itself is animated by Core Animation on the render server.
final class NotchController: NSObject, NSMenuDelegate {
    private enum Mode { case notch, compact, expanded }

    private struct Layout {
        var frame = NSRect.zero      // window frame (screen coordinates)
        var shape = CGSize.zero      // visible black shape
        var radius: CGFloat = 0
    }

    private let spotify: Spotify
    private let panel = NotchPanel()
    private let root = NotchRootView(frame: .zero)
    private var player: PlayerView?
    private var compact: CompactView?
    private var audioTap: AnyObject?            // AudioTap (macOS 14.2+); only alive while the wings show
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Sair do LightNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }()

    private var notchSize = CGSize.zero
    private var layouts: [Mode: Layout] = [:]
    private var mode = Mode.notch
    private var isOpen = false                  // user clicked to expand
    private var generation = 0                  // invalidates completion blocks of superseded transitions
    private var pendingClose: DispatchWorkItem?

    /// Copy of the artwork that flies between the compact and expanded cover slots.
    private let flyingCover: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.contentsGravity = .resizeAspectFill
        layer.zPosition = 10
        layer.isHidden = true
        return layer
    }()

    private var shape: CALayer { root.shape }
    /// The black shape and the content clip: every geometry change and animation goes to both.
    private var shapeLayers: [CALayer] { [root.shape, root.clip] }

    init(spotify: Spotify) {
        self.spotify = spotify
        super.init()
        panel.contentView = root
        root.onClick = { [weak self] in self?.toggle() }
        root.onHoverChange = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.cancelClose()
                self.bounce()
            } else {
                self.scheduleClose()
            }
        }
        root.contextMenu = { [weak self] in self?.mode == .notch ? nil : self?.menu }
        spotify.onChange = { [weak self] in self?.spotifyChanged() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layoutForScreen() }
        layoutForScreen()
        panel.orderFrontRegardless()
    }

    // MARK: Geometry

    private func layoutForScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            // No hardware notch: draw a virtual one as tall as the menu bar.
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: Metrics.virtualNotchWidth, height: menuBar > 0 ? menuBar : 24)
        }

        /// Window frame hugging `shape` at the top-center of the screen, with `margin` on the sides/bottom.
        func layout(_ shape: CGSize, radius: CGFloat, side: CGFloat, bottom: CGFloat) -> Layout {
            let w = shape.width + 2 * side, h = shape.height + bottom
            return Layout(frame: NSRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h).integral,
                          shape: shape, radius: radius)
        }
        let m = Metrics.springMargin
        let b = Metrics.bounceRoom
        layouts[.notch] = layout(notchSize, radius: Metrics.collapsedRadius, side: b, bottom: b)
        layouts[.compact] = layout(CGSize(width: notchSize.width + 2 * CompactView.wingWidth, height: notchSize.height),
                                   radius: Metrics.compactRadius, side: m, bottom: b)
        layouts[.expanded] = layout(CGSize(width: max(PlayerView.size.width + 2 * Metrics.sidePadding, notchSize.width),
                                           height: notchSize.height + Metrics.topGap + PlayerView.size.height + Metrics.bottomPadding),
                                    radius: Metrics.expandedRadius, side: m, bottom: m)
        compact?.layout(notchSize: notchSize)

        // Jump (without animation) to the right state for the new screen.
        pendingClose?.cancel()
        generation &+= 1
        isOpen = false
        mode = desiredMode
        let target = layouts[mode]!
        withoutActions {
            shapeLayers.forEach { $0.removeAllAnimations() }
            finishCoverFlight()
            setWindowFrame(target.frame)
            for layer in shapeLayers {
                layer.bounds = CGRect(origin: .zero, size: target.shape)
                layer.cornerRadius = target.radius
            }
        }
        syncHoverRect()
        showContent(for: mode, animated: false)
        updateAudioTap()
    }

    /// Resizes the window and re-pins everything to its top-center (the one point that never moves).
    private func setWindowFrame(_ frame: NSRect) {
        withoutActions {
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            let b = root.bounds
            shapeLayers.forEach { $0.position = CGPoint(x: b.midX, y: b.maxY) }
            player?.setFrameOrigin(NSPoint(x: ((b.width - PlayerView.size.width) / 2).rounded(),
                                           y: b.maxY - layouts[.expanded]!.shape.height + Metrics.bottomPadding))
            if let compact {
                compact.setFrameOrigin(NSPoint(x: ((b.width - compact.frame.width) / 2).rounded(),
                                               y: b.maxY - compact.frame.height))
            }
        }
        syncHoverRect()
    }

    /// Points the root's hover/click area at the shape's model rect (top-center of the window).
    private func syncHoverRect() {
        let b = root.bounds, size = shape.bounds.size
        root.hoverRect = NSRect(x: b.midX - size.width / 2, y: b.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: State machine

    private var desiredMode: Mode {
        if isOpen { return .expanded }
        return spotify.nowPlaying?.isPlaying == true ? .compact : .notch
    }

    private func toggle() {
        cancelClose()
        isOpen = mode != .expanded
        transition(to: desiredMode)
    }

    private func cancelClose() {
        pendingClose?.cancel()
        pendingClose = nil
    }

    private func scheduleClose() {
        guard isOpen else { return }
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClose = nil
            // Ignore spurious exits (e.g. while the window is resized under the cursor): test against the
            // visible shape, not the window (which has a transparent spring margin), with 1 pt of slack.
            if let open = self.layouts[.expanded] {
                let visible = NSRect(x: open.frame.midX - open.shape.width / 2, y: open.frame.maxY - open.shape.height,
                                     width: open.shape.width, height: open.shape.height)
                if visible.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) { return }
            }
            self.isOpen = false
            self.transition(to: self.desiredMode)
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.closeDelay, execute: work)
    }

    // Menu tracking can swallow mouseExited; re-check where the cursor ended up.
    func menuDidClose(_ menu: NSMenu) { scheduleClose() }

    private func spotifyChanged() {
        player?.update()
        compact?.update()
        transition(to: desiredMode)
        updateAudioTap()
    }

    /// Runs the audio tap only while the wings are visible and music plays; otherwise frees it.
    private func updateAudioTap() {
        guard #available(macOS 14.2, *) else { return }
        let wanted = mode == .compact && spotify.nowPlaying?.isPlaying == true
        if wanted, audioTap == nil {
            let tap = AudioTap()
            tap.onLevels = { [weak self, weak tap] levels in
                guard let self, let tap, self.audioTap === tap, let compact = self.compact else { return }
                if let levels { compact.setLevels(levels) } else { compact.useSyntheticAnimation() }
            }
            audioTap = tap
            tap.start { [weak self, weak tap] ok in
                // On failure the synthetic animation simply keeps running.
                guard !ok, let self, let tap, self.audioTap === tap else { return }
                self.audioTap = nil
            }
        } else if !wanted, let tap = audioTap as? AudioTap {
            tap.stop()
            audioTap = nil
            compact?.useSyntheticAnimation()
        }
    }

    private func transition(to newMode: Mode) {
        guard newMode != mode, let target = layouts[newMode], let current = layouts[mode] else { return }
        let oldMode = mode
        mode = newMode
        generation &+= 1
        let token = generation
        let growing = target.frame.width >= current.frame.width && target.frame.height >= current.frame.height
        let damping: CGFloat = newMode == .expanded ? 24 : 34

        showContent(for: newMode, animated: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Growing: make room first (the transparent window swap is invisible).
        if growing { setWindowFrame(target.frame) }
        CATransaction.setCompletionBlock { [weak self] in
            // Only if no newer transition happened meanwhile: shrink the window, hide faded-out views.
            guard let self, self.generation == token else { return }
            self.finishCoverFlight()
            if !growing { self.setWindowFrame(target.frame) }
            self.hideInvisibleContent()
        }
        animateShape(to: target.shape, radius: target.radius, damping: damping)
        flyCover(from: oldMode, to: newMode, damping: damping)
        CATransaction.commit()
        updateAudioTap()
    }

    // MARK: Shared cover

    /// Compact <-> expanded: the small wing cover grows into the player's cover (and back) along the same
    /// spring as the shape, while the real covers stay hidden. Must run inside the transition's transaction
    /// (its completion block calls `finishCoverFlight()`), after the window has been resized.
    private func flyCover(from oldMode: Mode, to newMode: Mode, damping: CGFloat) {
        let pair: Set<Mode> = [.compact, .expanded]
        guard pair.contains(oldMode), pair.contains(newMode),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let art = spotify.artwork, let player, let compact else {
            finishCoverFlight()
            return
        }
        if flyingCover.superlayer == nil { root.layer?.addSublayer(flyingCover) }
        flyingCover.contentsScale = panel.backingScaleFactor

        let small = compact.convert(compact.coverFrame, to: root)
        let large = player.convert(player.coverFrame, to: root)
        let (end, endRadius) = newMode == .expanded ? (large, PlayerView.coverRadius) : (small, CompactView.coverRadius)

        // Start from wherever the flying cover is on screen if a flight is interrupted.
        let startBounds: CGRect, startPosition: CGPoint, startRadius: CGFloat
        if !flyingCover.isHidden, let p = flyingCover.presentation() {
            (startBounds, startPosition, startRadius) = (p.bounds, p.position, p.cornerRadius)
        } else {
            let start = newMode == .expanded ? small : large
            startBounds = CGRect(origin: .zero, size: start.size)
            startPosition = CGPoint(x: start.midX, y: start.midY)
            startRadius = newMode == .expanded ? CompactView.coverRadius : PlayerView.coverRadius
        }

        compact.setCoverVisible(false)
        player.setCoverVisible(false)
        flyingCover.contents = art
        flyingCover.isHidden = false
        flyingCover.bounds = CGRect(origin: .zero, size: end.size)
        flyingCover.position = CGPoint(x: end.midX, y: end.midY)
        flyingCover.cornerRadius = endRadius

        let values: [(String, Any, Any)] = [
            ("bounds", NSValue(rect: startBounds), NSValue(rect: flyingCover.bounds)),
            ("position", NSValue(point: startPosition), NSValue(point: flyingCover.position)),
            ("cornerRadius", startRadius, endRadius),
        ]
        for (keyPath, from, to) in values {
            let anim = spring(keyPath, damping: damping)
            anim.fromValue = from
            anim.toValue = to
            flyingCover.add(anim, forKey: keyPath)
        }
    }

    /// Lands the flight: real covers back on, flying copy hidden.
    private func finishCoverFlight() {
        compact?.setCoverVisible(true)
        player?.setCoverVisible(true)
        guard !flyingCover.isHidden else { return }
        withoutActions {
            flyingCover.removeAllAnimations()
            flyingCover.isHidden = true
            flyingCover.contents = nil
        }
    }

    // MARK: Hover bounce

    /// Tiny squash-and-stretch of the shape when the cursor enters the idle notch or the wings,
    /// just to acknowledge it is there. The window always keeps `bounceRoom` around these shapes
    /// (resizing it on the fly lands a few frames late and clips the overshoot).
    private func bounce() {
        guard mode != .expanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let current = layouts[mode], current.shape.width > 0, current.shape.height > 0 else { return }
        let size = current.shape

        // Grows 2*dx wider and 2*dy taller (anchor is top-center, so it expands down and sideways).
        // Content shifts by half of that: dx sideways, dy down (vertical center of the grown shape).
        let dx: CGFloat = 3, dy: CGFloat = 1.5
        let peak = CATransform3DMakeScale((size.width + 2 * dx) / size.width, (size.height + 2 * dy) / size.height, 1)

        let bounce = bounceAnimation(peak: peak)
        shapeLayers.forEach { $0.add(bounce, forKey: "bounce") }
        // Wing content rides along: cover/equalizer follow the grown edges (translated, never stretched).
        if mode == .compact { compact?.bounce(dx: dx, dy: dy, animation: bounceAnimation) }
    }

    /// Ball-like hop: identity -> `peak` -> identity -> a smaller hop -> identity. Never goes past identity
    /// in the other direction (a spring would undershoot and shrink the shape, uncovering the real notch).
    private func bounceAnimation(peak: CATransform3D) -> CAAnimation {
        func lerp(_ t: CGFloat) -> NSValue {
            let i = CATransform3DIdentity
            var m = i
            m.m11 = i.m11 + (peak.m11 - i.m11) * t
            m.m22 = i.m22 + (peak.m22 - i.m22) * t
            m.m41 = peak.m41 * t
            m.m42 = peak.m42 * t
            return NSValue(caTransform3D: m)
        }
        let out = CAMediaTimingFunction(name: .easeOut)
        let into = CAMediaTimingFunction(name: .easeIn)

        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = [lerp(0), lerp(1), lerp(0), lerp(0.3), lerp(0)]
        anim.keyTimes = [0, 0.24, 0.55, 0.76, 1]
        anim.timingFunctions = [out, into, out, into]
        anim.duration = 0.42
        return anim
    }

    // MARK: Content

    /// Fades in the view that belongs to `mode` and fades out the other one. Views are created lazily.
    private func showContent(for mode: Mode, animated: Bool) {
        if mode == .expanded {
            let player = self.player ?? makePlayer()
            player.update()
            // Seeks and shuffle/repeat changes made inside Spotify send no notification: re-read on open.
            if animated {
                spotify.refreshTiming()
                spotify.refreshModes()
            }
            player.isHidden = false
            fade(player, to: 1, duration: animated ? 0.2 : 0, delay: animated ? 0.07 : 0)
        } else if let player, player.alphaValue > 0 {
            fade(player, to: 0, duration: animated ? 0.12 : 0, delay: 0)
        }

        if mode == .compact {
            let compact = self.compact ?? makeCompact()
            compact.update()
            compact.isHidden = false
            compact.setActive(true)
            fade(compact, to: 1, duration: animated ? 0.2 : 0, delay: animated ? 0.12 : 0)
        } else if let compact, compact.alphaValue > 0 {
            // Long enough to see the bars ease down to rest (CompactView settles them) while fading.
            compact.setActive(false)
            fade(compact, to: 0, duration: animated ? 0.25 : 0, delay: 0)
        }
        if !animated { hideInvisibleContent() }
    }

    /// Hidden views are skipped by hit-testing and rendering.
    private func hideInvisibleContent() {
        if mode != .expanded { player?.isHidden = true }
        if mode != .compact { compact?.isHidden = true }
    }

    private func makePlayer() -> PlayerView {
        let player = PlayerView(spotify: spotify)
        player.alphaValue = 0
        root.content.addSubview(player)
        self.player = player
        setWindowFrame(panel.frame)   // position it
        return player
    }

    private func makeCompact() -> CompactView {
        let compact = CompactView(spotify: spotify)
        compact.layout(notchSize: notchSize)
        compact.alphaValue = 0
        root.content.addSubview(compact)
        self.compact = compact
        setWindowFrame(panel.frame)   // position it
        return compact
    }

    // MARK: Animation helpers

    /// Springs the shape from wherever it currently is on screen (handles interrupted animations).
    private func animateShape(to size: CGSize, radius: CGFloat, damping: CGFloat) {
        let presentation = shape.presentation() ?? shape
        let target = CGRect(origin: .zero, size: size)

        let bounds = spring("bounds", damping: damping)
        bounds.fromValue = NSValue(rect: presentation.bounds)
        bounds.toValue = NSValue(rect: target)

        let corner = spring("cornerRadius", damping: damping)
        corner.fromValue = presentation.cornerRadius
        corner.toValue = radius

        for layer in shapeLayers {
            layer.bounds = target
            layer.cornerRadius = radius
            layer.add(bounds, forKey: "bounds")
            layer.add(corner, forKey: "cornerRadius")
        }
        syncHoverRect()
    }

    private func spring(_ keyPath: String, damping: CGFloat) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.mass = 1
        anim.stiffness = 260
        anim.damping = damping
        anim.duration = anim.settlingDuration
        return anim
    }

    private func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval) {
        guard let layer = view.layer, duration > 0 else {
            withoutActions { view.alphaValue = alpha }
            view.layer?.removeAnimation(forKey: "fade")
            return
        }
        let from = layer.presentation()?.opacity ?? Float(view.alphaValue)
        withoutActions { view.alphaValue = alpha }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = Float(alpha)
        anim.duration = duration
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .backwards
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "fade")
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
