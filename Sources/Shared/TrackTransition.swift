import AppKit

/// Track-change motion shared by the compact wings and the expanded player:
/// a card flip for the cover, a left-to-right color wave for the equalizer and a ticker roll for text.
/// Everything is explicit Core Animation (runs on the render server) plus short-lived helper layers.
enum TrackTransition {
    /// Time for the old cover to turn edge-on; the new cover, color wave and text land after it.
    static let flipOut: CFTimeInterval = 0.16

    // MARK: Cover flip

    /// Old art turns away around the vertical axis, then the new art (already in `layer`) turns in
    /// with a slight spring. Two throwaway layers inside a perspective container do the flip while
    /// the real layer is held invisible, so any anchor point / view-backed layer works.
    /// `backwards` (previous track) turns the card the other way.
    static func flipCover(_ layer: CALayer, from oldContents: Any?, oldBackground: CGColor?, backwards: Bool) {
        let side: CGFloat = backwards ? -1 : 1
        guard let superlayer = layer.superlayer, layer.bounds.width > 0 else { return }
        let size = layer.bounds.size

        let stage = CALayer()
        stage.frame = layer.frame
        stage.zPosition = layer.zPosition + 1
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (size.width * 2.5)
        stage.sublayerTransform = perspective

        func card(_ contents: Any?, _ background: CGColor?) -> CALayer {
            let card = CALayer()
            card.frame = CGRect(origin: .zero, size: size)
            card.contents = contents
            card.backgroundColor = contents == nil ? background : nil
            card.contentsGravity = .resizeAspectFill
            card.contentsScale = layer.contentsScale
            card.cornerRadius = layer.cornerRadius
            card.cornerCurve = layer.cornerCurve
            card.masksToBounds = true
            card.borderWidth = layer.borderWidth
            card.borderColor = layer.borderColor
            card.isDoubleSided = false
            stage.addSublayer(card)
            return card
        }
        let old = card(oldContents, oldBackground)
        let new = card(layer.contents, layer.backgroundColor)

        let now = CACurrentMediaTime()

        let out = CABasicAnimation(keyPath: "transform.rotation.y")
        out.fromValue = 0
        out.toValue = -side * CGFloat.pi / 2
        out.duration = flipOut
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false

        let dim = CABasicAnimation(keyPath: "opacity")   // a touch of shading as it turns away
        dim.fromValue = 1
        dim.toValue = 0.4
        dim.duration = flipOut
        dim.fillMode = .forwards
        dim.isRemovedOnCompletion = false

        let turnIn = CASpringAnimation(keyPath: "transform.rotation.y")
        turnIn.fromValue = side * CGFloat.pi / 2
        turnIn.toValue = 0
        turnIn.mass = 1
        turnIn.stiffness = 320
        turnIn.damping = 17
        turnIn.duration = turnIn.settlingDuration
        turnIn.beginTime = now + flipOut
        turnIn.fillMode = .backwards

        let total = flipOut + turnIn.duration
        let hold = CABasicAnimation(keyPath: "opacity")   // real layer stays hidden during the flip
        hold.fromValue = 0
        hold.toValue = 0
        hold.duration = total

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { stage.removeFromSuperlayer() }
        superlayer.insertSublayer(stage, above: layer)
        old.add(out, forKey: "flip")
        old.add(dim, forKey: "dim")
        new.transform = CATransform3DIdentity
        new.add(turnIn, forKey: "flip")
        layer.add(hold, forKey: "flipHold")
        CATransaction.commit()
    }

    // MARK: Equalizer color wave

    /// Recolors the bars one by one, each with a tiny pop, starting as the new cover lands.
    /// Left to right normally, right to left when going back.
    static func colorWave(_ bars: [CALayer], to color: CGColor, backwards: Bool) {
        let start = CACurrentMediaTime() + flipOut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in (backwards ? bars.reversed() : bars).enumerated() {
            let from = bar.presentation()?.backgroundColor ?? bar.backgroundColor
            bar.backgroundColor = color
            let begin = start + Double(i) * 0.07

            let tint = CABasicAnimation(keyPath: "backgroundColor")
            tint.fromValue = from
            tint.toValue = color
            tint.duration = 0.22
            tint.beginTime = begin
            tint.fillMode = .backwards
            tint.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(tint, forKey: "tint")

            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1, 1.35, 1]
            pop.keyTimes = [0, 0.4, 1]
            pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            pop.duration = 0.3
            pop.beginTime = begin
            bar.add(pop, forKey: "pop")
        }
        CATransaction.commit()
    }

    // MARK: Text roll

    /// Ticker-style roll: the new text pushes the old one out (clipped to the label);
    /// upwards normally, downwards when going back.
    static func roll(_ label: NSTextField, duration: CFTimeInterval, backwards: Bool) {
        guard let layer = label.layer else { return }
        layer.masksToBounds = true
        let push = CATransition()
        push.type = .push
        push.subtype = backwards ? .fromTop : .fromBottom
        push.duration = duration
        push.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        layer.add(push, forKey: "roll")
    }
}
