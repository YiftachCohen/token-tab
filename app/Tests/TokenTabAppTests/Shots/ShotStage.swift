// Token Tab — the headless shot stage.
//
// Renders the REAL SwiftUI views to a bitmap with no screen recording, no visible window and
// no manual screenshot. The interesting constraint is the panel's `.thinMaterial` glass
// (DropdownView): SwiftUI's `ImageRenderer` flattens a material into a dull slab and never
// fires `onAppear`, so it also freezes the open beat at 0 — a gauge photographed mid-sweep at
// zero. Both problems disappear if the view is hosted in a REAL NSWindow: vibrancy composites
// against whatever is behind it inside that window, and pumping the run loop lets the beat
// settle. So the stage builds the entire scene — backdrop, menu bar, panel — as one view
// hierarchy in one offscreen window and captures the whole thing with `cacheDisplay`.
//
// The window is positioned far off any screen and never ordered into a space the user sees.
// Capture resolution is the window's backing scale (2x on a Retina Mac) — the same pixels a
// Retina screenshot would produce.

import AppKit
import SwiftUI
@testable import TokenTab
@testable import TokenTabCore

/// Top-left origin, so scene layout reads the way the design does.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum ShotStage {

    /// How the panel is lit. `.desktop` is the marketing shot — glass over a wallpaper. `.plate`
    /// puts it on a flat near-solid ground, which is what a README wants: the material has
    /// nothing textured to blur, so the panel reads as a clean opaque card while still being
    /// the genuinely-rendered view (not an ImageRenderer approximation of one).
    enum Ground {
        case desktop
        case plate
    }

    struct Scene {
        var name: String
        var snapshot: Snapshot
        var scheme: ColorScheme
        var ground: Ground = .desktop
        var tab: PanelTab = .overview
        var settings: Bool = false
        var focus: Provider?
        var menuMetric: MenuMetric = .cost
        /// Wallpaper left below the panel — enough to clear the drop shadow and let the panel
        /// hang rather than sit on the bottom edge.
        var bottomPad: CGFloat = 48
    }

    // MARK: - Render

    /// Build the scene, let it settle, and return its pixels.
    @MainActor
    static func render(_ scene: Scene) -> NSBitmapImageRep? {
        let store = UsageStore(logDir: { nil }, codexDir: { nil })
        store.snapshot = scene.snapshot
        store.hasLoadedOnce = true
        store.menuMetric = scene.menuMetric
        if let focus = scene.focus { store.userFocus = focus }
        let access = AccessManager()
        access.bootstrap()
        let helper = LiveHelperManager()

        let panel = DropdownView(store: store, access: access, helper: helper,
                                 initialTab: scene.tab, initialSettings: scene.settings)
            .environment(\.colorScheme, scene.scheme)
        let panelHost = NSHostingView(rootView: AnyView(panel))
        let panelSize = panelHost.fittingSize

        let label = MenuBarLabel(snapshot: scene.snapshot, menuMetric: scene.menuMetric,
                                 scope: .both, now: Date(), selected: true)
            .environment(\.colorScheme, .dark)          // the bar is dark over any wallpaper
        let labelHost = NSHostingView(rootView: AnyView(label))
        let labelSize = labelHost.fittingSize

        // Scene geometry: a menu-bar corner with the panel hanging beneath its status item.
        let menuBarHeight: CGFloat = 24
        let sidePad: CGFloat = 64
        let canvas = CGSize(width: panelSize.width + sidePad * 2,
                            height: menuBarHeight + 10 + panelSize.height + scene.bottomPad)

        let container = FlippedView(frame: CGRect(origin: .zero, size: canvas))
        container.wantsLayer = true

        // 1. Ground.
        let backdrop = NSImageView(frame: container.bounds)
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.image = scene.ground == .desktop
            ? wallpaper(size: canvas, scheme: scene.scheme)
            : plate(size: canvas, scheme: scene.scheme)
        container.addSubview(backdrop)

        // 2. Menu bar: a translucent strip carrying the app's REAL label, drawn selected
        //    because a shot of an open panel is a shot of a status item mid-click.
        let bar = FlippedView(frame: CGRect(x: 0, y: 0, width: canvas.width, height: menuBarHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        let hairline = CALayer()
        hairline.frame = CGRect(x: 0, y: menuBarHeight - 0.5, width: canvas.width, height: 0.5)
        hairline.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        bar.layer?.addSublayer(hairline)
        container.addSubview(bar)

        // Right-to-left, the way the real menu bar packs: clock at the edge, then the status
        // item to its left with the selection fill behind it.
        let clock = NSTextField(labelWithString: clockText())
        clock.font = .systemFont(ofSize: 13, weight: .regular)
        clock.textColor = .white
        clock.sizeToFit()
        let clockX = canvas.width - sidePad + 10 - clock.frame.width
        clock.frame.origin = CGPoint(x: clockX, y: (menuBarHeight - clock.frame.height) / 2)
        bar.addSubview(clock)

        let labelX = clockX - 20 - labelSize.width
        let selection = FlippedView(frame: CGRect(x: labelX - 9, y: 1,
                                                  width: labelSize.width + 18, height: menuBarHeight - 2))
        selection.wantsLayer = true
        selection.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        selection.layer?.cornerRadius = 5
        bar.addSubview(selection)
        labelHost.frame = CGRect(x: labelX, y: (menuBarHeight - labelSize.height) / 2,
                                 width: labelSize.width, height: labelSize.height)
        bar.addSubview(labelHost)

        // 3. The panel, under its status item, with the popover's drop shadow. The shadow is a
        //    layer path rather than a SwiftUI `.shadow`, which would force a compositing group
        //    around the material and kill the vibrancy this whole approach exists to keep.
        let panelOrigin = CGPoint(x: canvas.width - sidePad - panelSize.width,
                                  y: menuBarHeight + 10)
        let panelFrame = CGRect(origin: panelOrigin, size: panelSize)
        let shadow = FlippedView(frame: panelFrame)
        shadow.wantsLayer = true
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = scene.ground == .desktop ? 0.55 : 0.28
        shadow.layer?.shadowRadius = 26
        shadow.layer?.shadowOffset = CGSize(width: 0, height: 14)
        shadow.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: panelSize),
                                          cornerWidth: 14, cornerHeight: 14, transform: nil)
        container.addSubview(shadow)
        panelHost.frame = panelFrame
        container.addSubview(panelHost)

        return capture(container, scheme: scene.scheme)
    }

    /// Host the scene in an offscreen window, let the open beat finish, and read the pixels.
    @MainActor
    private static func capture(_ container: NSView, scheme: ColorScheme) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = container
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The open beat is 0.6s (OpenBeat.duration); give it room plus a settling margin, or
        // the gauge is photographed mid-sweep.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        defer { window.orderOut(nil) }
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    // MARK: - Grounds

    /// A procedural wallpaper. Generated rather than shipped: a real photo would add a
    /// licensing question and a binary blob to a repo whose whole pitch is auditability, and
    /// the panel's blur eats most of the detail anyway. Soft, deep, and out of focus by design
    /// — the glass is the subject.
    private static func wallpaper(size: CGSize, scheme: ColorScheme) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
        let rect = CGRect(origin: .zero, size: size)

        let base = scheme == .dark ? rgb(0x0B0D12) : rgb(0xE8E4DE)
        ctx.setFillColor(base.cgColor)
        ctx.fill(rect)

        // Three wide, soft pools of color — the shapes a blurred desktop reduces to.
        let blobs: [(NSColor, CGPoint, CGFloat)] = scheme == .dark
            ? [(rgb(0x2B2F7A), CGPoint(x: 0.18, y: 0.16), 0.85),
               (rgb(0x0E5E58), CGPoint(x: 0.86, y: 0.34), 0.72),
               (rgb(0x64264A), CGPoint(x: 0.62, y: 0.94), 0.80)]
            : [(rgb(0xBFCBE8), CGPoint(x: 0.16, y: 0.14), 0.90),
               (rgb(0xE7D3BE), CGPoint(x: 0.88, y: 0.36), 0.78),
               (rgb(0xCFE0D6), CGPoint(x: 0.58, y: 0.96), 0.86)]

        ctx.setBlendMode(scheme == .dark ? .plusLighter : .normal)
        for (color, center, spread) in blobs {
            let point = CGPoint(x: center.x * size.width, y: center.y * size.height)
            let radius = spread * max(size.width, size.height)
            let colors = [color.withAlphaComponent(scheme == .dark ? 0.55 : 0.85).cgColor,
                          color.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: point, startRadius: 0,
                                   endCenter: point, endRadius: radius, options: [])
        }
        ctx.setBlendMode(.normal)

        // Vignette, so the panel sits in the brighter middle rather than floating on a flat field.
        let vignette = [NSColor.black.withAlphaComponent(0).cgColor,
                        NSColor.black.withAlphaComponent(scheme == .dark ? 0.45 : 0.16).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: vignette, locations: [0.35, 1]) {
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.drawRadialGradient(g, startCenter: mid, startRadius: 0, endCenter: mid,
                                   endRadius: max(size.width, size.height) * 0.75, options: [])
        }
        image.unlockFocus()
        return image
    }

    /// A near-flat ground for documentation shots: a whisper of a gradient so the panel edge
    /// still reads, but nothing for the glass to dissolve into.
    private static func plate(size: CGSize, scheme: ColorScheme) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let pair = scheme == .dark ? (rgb(0x191B21), rgb(0x0E1014)) : (rgb(0xF4F2EE), rgb(0xE3E0DA))
            let colors = [pair.0.cgColor, pair.1.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Small stuff

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The menu-bar clock, in the system's own short format so the strip reads as macOS.
    private static func clockText() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM  HH:mm"
        return f.string(from: Date())
    }
}
