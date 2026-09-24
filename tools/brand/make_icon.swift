// make_icon.swift — draws the aiFlow app icon (CoreGraphics, no dependencies).
//
//   swift tools/brand/make_icon.swift <out-dir>
//
// Writes icon_1024.png … icon_16.png for aiFlow/Assets.xcassets/AppIcon.appiconset
// and brand-mark.png (512) for the site. Design: macOS squircle on the icon
// grid, indigo → violet → cyan diagonal gradient, three white "flow" ribbons
// sweeping left to right (the files moving where they belong) and a four-point
// spark (the AI). Ribbons are thick and few so the mark still reads at 16 px.

import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Continuous-corner rounded rect (close to Apple's squircle).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let u = s / 1024 // design units: 1024 grid

    // macOS icon grid: 824 body centred, ~ 185 corner radius, soft shadow below.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let path = squircle(body, radius: 186 * u)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: color(0x1B0F5C, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(color(0x4B2FE0))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (top-left indigo → violet → bottom-right cyan).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [color(0x3A2BD8), color(0x7B3AED), color(0x14B8E6)] as CFArray,
                        locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 40 * u), options: [])

    // Flow ribbons: three S-curves, thick round strokes, fading downwards.
    func ribbon(y: CGFloat, amp: CGFloat, width: CGFloat, alpha: CGFloat) {
        let p = CGMutablePath()
        let x0 = body.minX + 140 * u, x1 = body.maxX - 140 * u
        let w = x1 - x0
        p.move(to: CGPoint(x: x0, y: y))
        p.addCurve(to: CGPoint(x: x0 + w * 0.5, y: y),
                   control1: CGPoint(x: x0 + w * 0.2, y: y + amp),
                   control2: CGPoint(x: x0 + w * 0.3, y: y + amp))
        p.addCurve(to: CGPoint(x: x1, y: y),
                   control1: CGPoint(x: x0 + w * 0.7, y: y - amp),
                   control2: CGPoint(x: x0 + w * 0.8, y: y - amp))
        ctx.addPath(p)
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color(0xFFFFFF, alpha))
        ctx.strokePath()
    }
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: color(0x160A4A, 0.30))
    let tiny = size <= 16 // Finder list / menu size: fewer, bolder shapes
    if tiny {
        ribbon(y: 560 * u, amp: 110 * u, width: 120 * u, alpha: 1.0)
        ribbon(y: 330 * u, amp: 110 * u, width: 120 * u, alpha: 0.6)
    } else {
        ribbon(y: 596 * u, amp: 96 * u, width: 74 * u, alpha: 1.0)
        ribbon(y: 452 * u, amp: 96 * u, width: 74 * u, alpha: 0.72)
        ribbon(y: 308 * u, amp: 96 * u, width: 74 * u, alpha: 0.45)
    }

    // AI spark: four-point star, top right.
    func spark(center c: CGPoint, r: CGFloat) {
        let p = CGMutablePath()
        let k: CGFloat = 0.22 // waist
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
        ctx.addPath(p)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
    }
    if tiny {
        spark(center: CGPoint(x: 760 * u, y: 770 * u), r: 120 * u)
    } else {
        spark(center: CGPoint(x: 736 * u, y: 760 * u), r: 88 * u)
        spark(center: CGPoint(x: 640 * u, y: 812 * u), r: 34 * u)
    }
    ctx.restoreGState()

    // Hairline inner edge for definition on light backgrounds.
    ctx.addPath(squircle(body.insetBy(dx: 1.5 * u, dy: 1.5 * u), radius: 185 * u))
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(drawIcon(size: size), "icon_\(size).png")
}
write(drawIcon(size: 512), "brand-mark.png")
print("wrote icons to \(outDir.path)")
