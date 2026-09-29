#!/usr/bin/env swift
// Gera o ícone do LightNotch (folha em tons de cinza) via CoreGraphics.
// Uso (a partir da raiz do projeto): swift Icon/make-icon.swift <saida.icns>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Desenho (grid de 1024, escalado para o tamanho pedido)

func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(gray: w, alpha: a)
}

func linearGradient(_ stops: [(CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { gray($0.0) } as CFArray
    let locs = stops.map { $0.1 }
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: locs)!
}

/// Constrói a folha em coordenadas locais (base em 0,0; ponta em L,0) e devolve
/// corpo, linha central (talo + nervura) e a transformação para o grid de 1024.
struct Leaf {
    let body: CGPath
    let stem: CGPath        // talo curvo, fora do corpo
    let midrib: CGPath      // nervura central, dentro do corpo
    let veins: CGPath       // nervuras laterais
    let bounds: CGRect

    init() {
        let L: CGFloat = 540
        let h: CGFloat = 158           // meia-largura máxima aproximada
        let angle: CGFloat = 42 * .pi / 180

        // Corpo: duas Béziers simétricas, base arredondada, ponta afilada.
        let body = CGMutablePath()
        let base = CGPoint(x: 0, y: 0)
        let tip = CGPoint(x: L, y: 0)
        body.move(to: base)
        body.addCurve(to: tip,
                      control1: CGPoint(x: -0.02 * L, y: 1.42 * h),
                      control2: CGPoint(x: 0.58 * L, y: 1.02 * h))
        body.addCurve(to: base,
                      control1: CGPoint(x: 0.58 * L, y: -1.02 * h),
                      control2: CGPoint(x: -0.02 * L, y: -1.42 * h))
        body.closeSubpath()

        // Talo curvo saindo da base (para trás e levemente para baixo).
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 0.08 * L, y: 0))
        stem.addCurve(to: CGPoint(x: -0.20 * L, y: -0.075 * L),
                      control1: CGPoint(x: -0.03 * L, y: 0.0),
                      control2: CGPoint(x: -0.12 * L, y: -0.03 * L))

        // Nervura central.
        let midrib = CGMutablePath()
        midrib.move(to: CGPoint(x: 0.02 * L, y: 0))
        midrib.addLine(to: CGPoint(x: 0.80 * L, y: 0))

        // Nervuras laterais discretas (3 pares).
        let veins = CGMutablePath()
        for (t, len) in [(0.28, 0.17), (0.45, 0.17), (0.62, 0.13)] as [(CGFloat, CGFloat)] {
            let p = CGPoint(x: t * L, y: 0)
            let dx = len * L * 0.85, dy = len * L * 0.55
            veins.move(to: p)
            veins.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy))
            veins.move(to: p)
            veins.addLine(to: CGPoint(x: p.x + dx, y: p.y - dy))
        }

        // Transformação: rotaciona e centra (ótica) o conjunto folha+talo no squircle.
        let rot = CGAffineTransform(rotationAngle: angle)
        let all = CGMutablePath()
        all.addPath(body)
        all.addPath(stem)
        let raw = all.boundingBoxOfPath.applying(rot)
        // Centro ótico: o corpo pesa mais que o talo, então mistura bbox total e do corpo.
        let bodyBox = body.boundingBoxOfPath.applying(rot)
        let cx = raw.midX * 0.5 + bodyBox.midX * 0.5
        let cy = raw.midY * 0.5 + bodyBox.midY * 0.5
        let xf = rot.concatenating(CGAffineTransform(translationX: 512 - cx, y: 512 - cy + 14))

        var xfv = xf
        func t(_ p: CGPath) -> CGPath { p.copy(using: &xfv)! }
        self.body = t(body)
        self.stem = t(stem)
        self.midrib = t(midrib)
        self.veins = t(veins)
        self.bounds = self.body.boundingBoxOfPath
    }
}

func drawIcon(into ctx: CGContext, pixels: Int) {
    let s = CGFloat(pixels) / 1024
    let small = pixels <= 32
    let tiny = pixels <= 16
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // --- Squircle ---
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: gray(0, 0.28))
        ctx.setFillColor(gray(0.11))
        ctx.addPath(squircle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = linearGradient([(0.20, 0), (0.11, 1)])
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Realce sutil na borda superior (linha interna clara que esmaece para baixo).
    if !small {
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let inner = squircle.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        ctx.addPath(inner)
        ctx.clip()
        let hl = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                            colorComponents: [1, 0.10, 1, 0.0],
                            locations: [0, 1], count: 2)!
        ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.maxY - 260), options: [])
        ctx.restoreGState()
    }

    // --- Folha ---
    let leaf = Leaf()

    // Sombra suave sob a folha (profundidade).
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: gray(0, 0.40))
        ctx.setFillColor(gray(0.85))
        ctx.addPath(leaf.body)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Talo (traço arredondado, cinza claro).
    let stemWidth: CGFloat = tiny ? 40 : (small ? 30 : 26)
    ctx.saveGState()
    ctx.setStrokeColor(gray(0.84))
    ctx.setLineWidth(stemWidth)
    ctx.setLineCap(.round)
    ctx.addPath(leaf.stem)
    ctx.strokePath()
    ctx.restoreGState()

    // Corpo com gradiente.
    ctx.saveGState()
    ctx.addPath(leaf.body)
    ctx.clip()
    let b = leaf.bounds
    let lg = linearGradient([(0.96, 0), (0.78, 1)])
    ctx.drawLinearGradient(lg, start: CGPoint(x: b.midX, y: b.maxY), end: CGPoint(x: b.midX, y: b.minY), options: [])

    // Nervuras laterais (só em tamanhos maiores).
    if pixels >= 128 {
        ctx.setStrokeColor(gray(0.52, 0.55))
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.addPath(leaf.veins)
        ctx.strokePath()
    }

    // Nervura central: "recorte negativo" na cor do fundo, um pouco mais escura no tamanho pequeno.
    ctx.setStrokeColor(gray(pixels >= 128 ? 0.50 : 0.40))
    ctx.setLineWidth(tiny ? 0 : (small ? 26 : 12))
    ctx.setLineCap(.round)
    if !tiny {
        ctx.addPath(leaf.midrib)
        ctx.strokePath()
    }
    ctx.restoreGState()

    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawIcon(into: ctx, pixels: pixels)
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("uso: swift Icon/make-icon.swift <saida.icns>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: args[1])
let fm = FileManager.default
try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconset = fm.temporaryDirectory.appendingPathComponent("LightNotch-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try renderPNG(pixels: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil falhou (\(p.terminationStatus))\n".utf8))
    exit(1)
}
print("Gerado: \(output.path)")
