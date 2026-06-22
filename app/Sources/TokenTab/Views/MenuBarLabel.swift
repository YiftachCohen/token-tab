// Token Tab — the menu-bar glyph.
//
// The number is decided by the active mode, and so is the glyph, matching each mock:
//   • Subscription → a runway RING (mono track + colored arc filled to runway-left) plus
//     "{remaining}%" of the window — token-% with a cap, else exact time remaining.
//   • Burn (Bedrock/API) → a health dot plus "$5.10" or "22.9M" today, per the toggle.
//
// The glyph is drawn as an NSImage (not a SwiftUI Shape): MenuBarExtra reliably renders
// Text and Image, but drops custom shape-drawing in the status item — which is exactly
// why the ring was invisible. The number stays monochrome so it's legible on any
// wallpaper; the ring/dot is the one spot we spend color.

import SwiftUI
import AppKit
import TokenTabCore

struct MenuBarLabel: View {
    let snapshot: Snapshot
    let menuMetric: MenuMetric
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: glyph)
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    private var glyph: NSImage {
        switch snapshot.mode {
        case .subscription:
            return MenuGlyph.ring(fraction: ringFraction, arc: NSColor(snapshot.health.color))
        case .burn:
            return MenuGlyph.dot(color: NSColor(snapshot.health.color))
        }
    }

    /// Runway-left fraction for the ring (mirrors the panel ring; 0 when idle).
    private var ringFraction: Double {
        guard let pct = snapshot.agg.window.runwayLeftPercent(now: now) else { return 0 }
        return Double(pct) / 100
    }

    private var text: String {
        switch snapshot.mode {
        case .subscription:
            if let pct = snapshot.agg.window.runwayLeftPercent(now: now) { return "\(pct)%" }
            return "—"
        case .burn:
            switch menuMetric {
            case .cost:   return Fmt.usd(snapshot.agg.cost?.today ?? 0)
            case .tokens: return Fmt.millions(snapshot.agg.today)
            }
        }
    }
}

/// NSImage glyphs for the menu bar. The track uses a dynamic system color so it stays
/// readable on both light and dark bars; the arc/dot carries the brand/health color.
enum MenuGlyph {
    static func ring(fraction: Double, arc: NSColor, diameter: CGFloat = 13, lineWidth: CGFloat = 2) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            let inset = lineWidth / 2 + 0.5
            let r = rect.insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = r.width / 2

            // Track (full faint circle).
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()

            // Arc: from 12 o'clock, clockwise, swept by `fraction`.
            let f = max(0, min(1, fraction))
            if f > 0 {
                let start: CGFloat = 90
                let arcPath = NSBezierPath()
                if f >= 0.999 {
                    arcPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                } else {
                    arcPath.appendArc(withCenter: center, radius: radius,
                                      startAngle: start, endAngle: start - CGFloat(f) * 360,
                                      clockwise: true)
                }
                arcPath.lineWidth = lineWidth
                arcPath.lineCapStyle = .round
                arc.setStroke()
                arcPath.stroke()
            }
            return true
        }
        img.isTemplate = false   // keep the colored arc; track adapts via the dynamic system color
        return img
    }

    static func dot(color: NSColor, diameter: CGFloat = 8) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
