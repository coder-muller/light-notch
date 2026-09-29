import CoreGraphics

/// Accent color taken from the cover (equalizer bars, progress bar). One-entry cache, so the
/// compact wings and the player share a single computation per cover.
enum Accent {
    /// No cover: Spotify green #1DB954.
    static let fallback = CGColor(srgbRed: 29 / 255, green: 185 / 255, blue: 84 / 255, alpha: 1)

    private static var cached: (image: CGImage, color: CGColor)?

    /// Main thread only.
    static func color(for image: CGImage?) -> CGColor {
        guard let image else { return fallback }
        if let cached, cached.image === image { return cached.color }
        let color = extract(from: image)
        cached = (image, color)
        return color
    }

    /// Dominant "vibrant" color of a cover, tuned to read on a black background.
    /// Cost: one 16x16 draw + 256 pixel loop; the bitmap is local and freed on return.
    private static func extract(from image: CGImage) -> CGColor {
        let fallback = CGColor(gray: 1, alpha: 0.9)
        let n = 16
        let hueBuckets = 12
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return fallback }

        // Per hue bucket: pixel count, summed score and score-weighted hue/saturation/brightness.
        var count = [Int](repeating: 0, count: hueBuckets)
        var score = [CGFloat](repeating: 0, count: hueBuckets)
        var sumH = [CGFloat](repeating: 0, count: hueBuckets)
        var sumS = [CGFloat](repeating: 0, count: hueBuckets)
        var sumV = [CGFloat](repeating: 0, count: hueBuckets)

        for p in 0..<(n * n) {
            let a = CGFloat(pixels[p * 4 + 3]) / 255
            if a < 0.5 { continue }
            // Un-premultiply.
            let r = min(1, CGFloat(pixels[p * 4]) / 255 / a)
            let g = min(1, CGFloat(pixels[p * 4 + 1]) / 255 / a)
            let b = min(1, CGFloat(pixels[p * 4 + 2]) / 255 / a)
            let maxC = max(r, g, b), minC = min(r, g, b)
            let v = maxC
            let delta = maxC - minC
            let s = maxC > 0 ? delta / maxC : 0
            if s < 0.2 || v < 0.2 { continue }   // gray / near-black / near-white: no color information

            var h: CGFloat
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }

            let bucket = min(hueBuckets - 1, Int(h * CGFloat(hueBuckets)))
            let w = s * v
            count[bucket] += 1
            score[bucket] += w
            sumH[bucket] += h * w
            sumS[bucket] += s * w
            sumV[bucket] += v * w
        }

        // Pick the best bucket; neighbours contribute half so a hue straddling a boundary is not split.
        var best = -1
        var bestScore: CGFloat = 0
        for b in 0..<hueBuckets {
            let total = score[b] + 0.5 * (score[(b + 1) % hueBuckets] + score[(b + hueBuckets - 1) % hueBuckets])
            if total > bestScore { bestScore = total; best = b }
        }
        // Need a minimum share of colored pixels (~2%), otherwise the cover is effectively grayscale.
        guard best >= 0, count[best] >= 5, score[best] > 0 else { return fallback }

        let w = score[best]
        let h = sumH[best] / w
        var s = sumS[best] / w
        var v = sumV[best] / w
        s = min(1, max(s, 0.55))
        if v < 0.65 { v = 0.72 }   // stay readable over black without changing the hue

        // HSB -> sRGB.
        let hp = h * 6
        let c = v * s
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (CGFloat, CGFloat, CGFloat)
        switch Int(hp) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return CGColor(srgbRed: r1 + m, green: g1 + m, blue: b1 + m, alpha: 1)
    }
}
