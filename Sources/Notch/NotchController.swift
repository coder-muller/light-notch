import AppKit

private enum Metrics {
    static let sidePadding: CGFloat = 20
    static let topGap: CGFloat = 8
    static let bottomPadding: CGFloat = 16
    static let collapsedRadius: CGFloat = 10
    static let compactRadius: CGFloat = 12
    static let expandedRadius: CGFloat = 24
    static let springMargin: CGFloat = 8
    static let bounceRoom: CGFloat = 4
    static let closeDelay: TimeInterval = 0.25
    static let virtualNotchWidth: CGFloat = 185
    static let volumeRow: CGFloat = 26
    static let volumeRadius: CGFloat = 18
    static let volumeInset: CGFloat = 16
    static let peekRow: CGFloat = 46
    static let hoverOpenDelay: TimeInterval = 0.35
}

final class NotchController: NSObject, NSMenuDelegate {
    private enum Mode {
        case notch, compact, compactVolume, compactPeek, expanded
        var showsWings: Bool { self == .compact || self == .compactVolume || self == .compactPeek }
    }

    private struct Layout {
        var frame = NSRect.zero
        var shape = CGSize.zero
        var radius: CGFloat = 0
    }

    private let spotify: Spotify
    private let systemVolume = SystemVolume()
    private let panel = NotchPanel()
    private let root = NotchRootView(frame: .zero)
    private var player: PlayerView?
    private var compact: CompactView?
    private var audioTap: AnyObject?
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LightNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }()
    private var settings: SettingsWindowController?

    private var notchSize = CGSize.zero
    private var layouts: [Mode: Layout] = [:]
    private var mode = Mode.notch
    private var isOpen = false
    private var generation = 0
    private var pendingClose: DispatchWorkItem?
    private var volumeRemainder: CGFloat = 0
    private var hoverOpen: DispatchWorkItem?
    private var volumeShown = false
    private var peekShown = false
    private var peekHide: DispatchWorkItem?
    private var seenTrackID: String?
    private let trackPeek: TrackPeekView = {
        let peek = TrackPeekView(frame: .zero)
        peek.alphaValue = 0
        return peek
    }()
    private var volumeHide: DispatchWorkItem?
    private let compactMeter: VolumeMeter = {
        let meter = VolumeMeter(frame: .zero, iconSize: 11, barHeight: 6)
        meter.alphaValue = 0
        return meter
    }()

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
    private var shapeLayers: [CALayer] { [root.shape, root.clip] }

    init(spotify: Spotify) {
        self.spotify = spotify
        super.init()
        systemVolume.onChange = { [weak self] in self?.syncOutputSilent() }
        panel.contentView = root
        root.onClick = { [weak self] in self?.toggle() }
        root.onHoverChange = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.cancelClose()
                self.bounce()
                self.scheduleHoverOpen()
            } else {
                self.hoverOpen?.cancel()
                self.scheduleClose()
            }
        }
        root.contextMenu = { [weak self] in self?.menu }
        root.onScroll = { [weak self] event in self?.scrolled(event) }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil,
                                               queue: .main) { [weak self] _ in self?.preferencesChanged() }
        spotify.onChange = { [weak self] in self?.spotifyChanged() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layoutForScreen() }
        layoutForScreen()
        panel.orderFrontRegardless()
    }

    private func layoutForScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: Metrics.virtualNotchWidth, height: menuBar > 0 ? menuBar : 24)
        }

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
        layouts[.compactVolume] = layout(CGSize(width: notchSize.width + 2 * CompactView.wingWidth,
                                                height: notchSize.height + Metrics.volumeRow),
                                         radius: Metrics.volumeRadius, side: m, bottom: m)
        layouts[.compactPeek] = layout(CGSize(width: notchSize.width + 2 * CompactView.wingWidth,
                                              height: notchSize.height + Metrics.peekRow),
                                       radius: Metrics.volumeRadius, side: m, bottom: m)
        layouts[.expanded] = layout(CGSize(width: max(PlayerView.size.width + 2 * Metrics.sidePadding, notchSize.width),
                                           height: notchSize.height + Metrics.topGap + PlayerView.size.height + Metrics.bottomPadding),
                                    radius: Metrics.expandedRadius, side: m, bottom: m)
        compact?.layout(notchSize: notchSize)

        pendingClose?.cancel()
        volumeHide?.cancel()
        volumeShown = false
        peekHide?.cancel()
        peekShown = false
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
            let meterWidth = notchSize.width + 2 * CompactView.wingWidth - 2 * Metrics.volumeInset
            trackPeek.frame = NSRect(x: ((b.width - meterWidth) / 2).rounded(),
                                     y: b.maxY - notchSize.height - 4 - TrackPeekView.height,
                                     width: meterWidth, height: TrackPeekView.height)
            compactMeter.frame = NSRect(x: ((b.width - meterWidth) / 2).rounded(), y: b.maxY - notchSize.height - 19,
                                        width: meterWidth, height: 14)
        }
        syncHoverRect()
    }

    private func syncHoverRect() {
        let b = root.bounds, size = shape.bounds.size
        root.hoverRect = NSRect(x: b.midX - size.width / 2, y: b.maxY - size.height, width: size.width, height: size.height)
    }

    private var desiredMode: Mode {
        if isOpen { return .expanded }
        guard let track = spotify.nowPlaying, track.isPlaying || Preferences.shared.keepWhilePaused else { return .notch }
        if volumeShown { return .compactVolume }
        return peekShown ? .compactPeek : .compact
    }

    private func toggle() {
        cancelClose()
        hoverOpen?.cancel()
        isOpen = mode != .expanded
        transition(to: desiredMode)
    }

    private func scrolled(_ event: NSEvent) {
        guard Preferences.shared.scrollVolume, mode != .notch, spotify.nowPlaying != nil,
              event.momentumPhase.isEmpty else { return }
        let useSystem = Preferences.shared.volumeSource == .system
        guard let volume = useSystem ? systemVolume.level : spotify.volume else {
            if !useSystem { spotify.refreshVolume() }
            return
        }
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        volumeRemainder += event.hasPreciseScrollingDeltas ? dy * 0.25 : dy * 4
        let step = volumeRemainder.rounded(.towardZero)
        guard step != 0 else { return }
        volumeRemainder -= step
        let target = min(100, max(0, volume + Int(step)))
        if target != volume || (useSystem && systemVolume.isMuted && step > 0) {
            if useSystem { systemVolume.setLevel(target) } else { spotify.setVolume(target) }
        }
        let level = CGFloat(target) / 100
        if mode == .expanded {
            player?.showVolume(level)
        } else {
            compactMeter.setLevel(level, animated: mode == .compactVolume)
            showCompactVolume()
        }
    }

    private func showCompactVolume() {
        peekHide?.cancel()
        peekShown = false
        volumeShown = true
        transition(to: desiredMode)
        volumeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.volumeShown = false
            self.transition(to: self.desiredMode)
        }
        volumeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.shared.volumeDelay, execute: work)
    }

    private func notePeek() {
        guard let track = spotify.nowPlaying, track.trackID != seenTrackID else { return }
        if seenTrackID == nil || isOpen {
            seenTrackID = track.trackID
            return
        }
        guard track.isPlaying else { return }
        seenTrackID = track.trackID
        guard Preferences.shared.trackNotice, !volumeShown else { return }
        trackPeek.show(track, animated: mode == .compactPeek, backwards: spotify.lastChangeWentBack)
        peekShown = true
        peekHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.peekShown = false
            self.transition(to: self.desiredMode)
        }
        peekHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.shared.peekDelay, execute: work)
    }

    private func scheduleHoverOpen() {
        hoverOpen?.cancel()
        guard Preferences.shared.openOnHover, mode != .expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode != .expanded else { return }
            self.isOpen = true
            self.transition(to: self.desiredMode)
        }
        hoverOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.hoverOpenDelay, execute: work)
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

    func menuDidClose(_ menu: NSMenu) { scheduleClose() }

    @objc private func openSettings() {
        let settings = self.settings ?? SettingsWindowController { [weak self] in self?.spotify.artwork }
        self.settings = settings
        settings.show()
    }

    private func syncOutputSilent() {
        let silent = Preferences.shared.volumeSource == .system ? systemVolume.isSilent : spotify.volume == 0
        compact?.setOutputSilent(silent)
    }

    private func preferencesChanged() {
        syncOutputSilent()
        compact?.update()
        player?.update()
        compactMeter.setAccent(Accent.color(for: spotify.artwork), animated: true)
        transition(to: desiredMode)
        updateAudioTap()
    }

    private func spotifyChanged() {
        player?.update()
        compact?.update()
        settings?.refresh()
        syncOutputSilent()
        notePeek()
        transition(to: desiredMode)
        updateAudioTap()
    }

    private func updateAudioTap() {
        guard #available(macOS 14.2, *) else { return }
        let wanted = mode.showsWings && spotify.nowPlaying?.isPlaying == true
            && Preferences.shared.equalizer == .live
        if wanted, audioTap == nil {
            let tap = AudioTap()
            tap.onLevels = { [weak self, weak tap] levels in
                guard let self, let tap, self.audioTap === tap, let compact = self.compact else { return }
                if let levels { compact.setLevels(levels) } else { compact.useSyntheticAnimation() }
            }
            audioTap = tap
            tap.start { [weak self, weak tap] ok in
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
        let damping: CGFloat = newMode == .expanded ? 24 : newMode == .compact || newMode == .notch ? 34 : 26

        showContent(for: newMode, animated: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if growing { setWindowFrame(target.frame) }
        CATransaction.setCompletionBlock { [weak self] in
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

    private func flyCover(from oldMode: Mode, to newMode: Mode, damping: CGFloat) {
        guard oldMode.showsWings || oldMode == .expanded, newMode.showsWings || newMode == .expanded,
              oldMode == .expanded || newMode == .expanded,
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

    private func bounce() {
        guard Preferences.shared.hoverBounce, mode == .notch || mode == .compact, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let current = layouts[mode], current.shape.width > 0, current.shape.height > 0 else { return }
        let size = current.shape

        let dx: CGFloat = 3, dy: CGFloat = 1.5
        let peak = CATransform3DMakeScale((size.width + 2 * dx) / size.width, (size.height + 2 * dy) / size.height, 1)

        let bounce = bounceAnimation(peak: peak)
        shapeLayers.forEach { $0.add(bounce, forKey: "bounce") }
        if mode == .compact { compact?.bounce(dx: dx, dy: dy, animation: bounceAnimation) }
    }

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

    private func showContent(for mode: Mode, animated: Bool) {
        if mode == .expanded {
            let player = self.player ?? makePlayer()
            player.update()
            if animated {
                spotify.refreshTiming()
                spotify.refreshModes()
            }
            player.isHidden = false
            fade(player, to: 1, duration: animated ? 0.2 : 0, delay: animated ? 0.07 : 0)
        } else if let player, player.alphaValue > 0 {
            fade(player, to: 0, duration: animated ? 0.12 : 0, delay: 0)
        }

        if mode == .compactPeek {
            if trackPeek.superview == nil { root.content.addSubview(trackPeek) }
            VolumeMeter.fade(trackPeek, to: 1, duration: animated ? 0.22 : 0)
        } else if trackPeek.alphaValue > 0 {
            VolumeMeter.fade(trackPeek, to: 0, duration: animated ? 0.12 : 0)
        }

        if mode == .compactVolume {
            if compactMeter.superview == nil { root.content.addSubview(compactMeter) }
            compactMeter.setAccent(Accent.color(for: spotify.artwork), animated: false)
            VolumeMeter.fade(compactMeter, to: 1, duration: animated ? 0.2 : 0)
        } else if compactMeter.alphaValue > 0 {
            VolumeMeter.fade(compactMeter, to: 0, duration: animated ? 0.12 : 0)
        }

        if mode.showsWings {
            let compact = self.compact ?? makeCompact()
            compact.update()
            compact.isHidden = false
            compact.setActive(true)
            spotify.refreshVolume()
            fade(compact, to: 1, duration: animated ? 0.2 : 0, delay: animated ? 0.12 : 0)
        } else if let compact, compact.alphaValue > 0 {
            compact.setActive(false)
            fade(compact, to: 0, duration: animated ? 0.25 : 0, delay: 0)
        }
        if !animated { hideInvisibleContent() }
    }

    private func hideInvisibleContent() {
        if mode != .expanded { player?.isHidden = true }
        if !mode.showsWings { compact?.isHidden = true }
    }

    private func makePlayer() -> PlayerView {
        let player = PlayerView(spotify: spotify)
        player.alphaValue = 0
        root.content.addSubview(player)
        self.player = player
        setWindowFrame(panel.frame)
        return player
    }

    private func makeCompact() -> CompactView {
        let compact = CompactView(spotify: spotify)
        compact.layout(notchSize: notchSize)
        compact.alphaValue = 0
        root.content.addSubview(compact)
        self.compact = compact
        syncOutputSilent()
        setWindowFrame(panel.frame)
        return compact
    }

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
