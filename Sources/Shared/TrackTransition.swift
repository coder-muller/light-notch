import AppKit

enum TrackTransition {
    static let flipOut: CFTimeInterval = 0.16

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

        let dim = CABasicAnimation(keyPath: "opacity")
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
        let hold = CABasicAnimation(keyPath: "opacity")
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
