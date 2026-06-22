#!/usr/bin/env swift
// Token Tab — render the V1 · Gauge mark to PNGs.
//
// Draws the gauge icon (dark squircle + live progress ring) with Core Graphics so it
// stays crisp at every size and regenerates deterministically — no external rasterizer.
// Three presets:
//   iconset  → the 10 macOS .iconset PNGs (margin + contact shadow), for AppIcon.icns
//   favicon  → full-bleed web sizes (16/32/48/180/192/512), for favicon.* + touch icon
//   hero     → one 512px PNG (margin + shadow), the README/app-store hero shot
//
// Usage:  swift make-icon.swift <out-dir> [iconset|favicon|hero]   (default: iconset)

import AppKit

// ── gauge geometry, as fractions of the squircle tile (the design's 104px tile) ──
// Ring r=18, stroke 6 in a 56-unit viewBox rendered at 60px inside a 104px tile.
let ringRadiusFrac: CGFloat = 19.2857 / 104.0   // 0.18544
let ringStrokeFrac: CGFloat = 6.42857 / 104.0   // 0.06181
let progressFrac:   CGFloat = 1.0 - 34.0 / 113.097   // 0.6994  (~70%, dashoffset 34)
let cornerFrac:     CGFloat = 24.0 / 104.0       // border-radius 24 on a 104 tile

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

/// Render the gauge to a PNG. `fullBleed` drops the margin + shadow (web/favicon use).
func renderPNG(size: CGFloat, fullBleed: Bool) -> Data {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // squircle tile. Full-bleed for web; inset (macOS icon grid) for the app icon.
    let inset = fullBleed ? 0 : (size * 0.0977).rounded()
    let body = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let tile = body.width
    let corner = tile * cornerFrac
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

    // soft contact shadow under the tile (app icon only)
    if !fullBleed {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                     blur: size * 0.03, color: c(0, 0, 0, 0.30).cgColor)
        c(0, 0, 0, 1).setFill()
        bodyPath.fill()
        cg.restoreGState()
    }

    // dark gradient fill (CSS linear-gradient(160deg, #26272e, #15161b))
    cg.saveGState()
    bodyPath.addClip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [c(0x26, 0x27, 0x2e).cgColor, c(0x15, 0x16, 0x1b).cgColor] as CFArray,
                          locations: [0, 1])!
    // 160deg ≈ down-and-slightly-right: lighter at top-left, darker at bottom-right.
    let start = CGPoint(x: body.minX + body.width*0.329, y: body.maxY - body.height*0.030)
    let end   = CGPoint(x: body.minX + body.width*0.671, y: body.maxY - body.height*0.970)
    cg.drawLinearGradient(grad, start: start, end: end,
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // inner top highlight (inset 0 1px 0 rgba(255,255,255,.06))
    cg.saveGState()
    bodyPath.addClip()
    c(255, 255, 255, 0.06).setStroke()
    let hi = NSBezierPath(roundedRect: body.insetBy(dx: size*0.002, dy: size*0.002),
                          xRadius: corner, yRadius: corner)
    hi.lineWidth = max(1, size * 0.004)
    hi.stroke()
    cg.restoreGState()

    // gauge
    let center = CGPoint(x: body.midX, y: body.midY)
    let R = tile * ringRadiusFrac
    let stroke = tile * ringStrokeFrac

    // background ring (full circle, white @ 18%)
    let bg = NSBezierPath()
    bg.appendArc(withCenter: center, radius: R, startAngle: 0, endAngle: 360)
    bg.lineWidth = stroke
    c(255, 255, 255, 0.18).setStroke()
    bg.stroke()

    // progress arc (green, round cap) from the top (12 o'clock), clockwise
    let sweep = progressFrac * 360
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: R, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    c(0x36, 0xc9, 0x8a).setStroke()
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ── presets ──
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out-dir> [iconset|favicon|hero]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]
let preset = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "iconset"

// (filename, pixel size, fullBleed)
let specs: [(String, CGFloat, Bool)]
switch preset {
case "iconset":
    specs = [("icon_16x16.png", 16, false), ("icon_16x16@2x.png", 32, false),
             ("icon_32x32.png", 32, false), ("icon_32x32@2x.png", 64, false),
             ("icon_128x128.png", 128, false), ("icon_128x128@2x.png", 256, false),
             ("icon_256x256.png", 256, false), ("icon_256x256@2x.png", 512, false),
             ("icon_512x512.png", 512, false), ("icon_512x512@2x.png", 1024, false)]
case "favicon":
    specs = [("favicon-16.png", 16, true), ("favicon-32.png", 32, true),
             ("favicon-48.png", 48, true), ("apple-touch-icon.png", 180, true),
             ("favicon-192.png", 192, true), ("favicon-512.png", 512, true)]
case "hero":
    specs = [("gauge-appicon.png", 512, false)]
default:
    FileHandle.standardError.write("unknown preset: \(preset)\n".data(using: .utf8)!)
    exit(2)
}

for (name, sz, full) in specs {
    let data = renderPNG(size: sz, fullBleed: full)
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("  \(name) (\(Int(sz))px)")
}
