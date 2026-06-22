// Token Tab — colors + type, lifted from the design tokens.
//
// The dropdown is glass (system material) and ADAPTS to light/dark like a real menu-bar
// panel — but every tier is tuned to the mock so it reads premium in both: warm greys in
// light (the subscription mock), cool blue-greys in dark (the Bedrock mock), vivid brand
// accents, and a crisp hairline so the panel floats.

import SwiftUI
import AppKit

enum Theme {
    // Brand accents (brighter in dark, per the design's light/dark pairs).
    static let green  = dynamic(light: 0x2E9E63, dark: 0x36C98A)
    static let indigo = dynamic(light: 0x5B62D6, dark: 0x7C83F0)   // Codex
    static let amber  = dynamic(light: 0xB06A1F, dark: 0xD6A45A)
    static let red    = dynamic(light: 0xD65745, dark: 0xE06A55)

    // Text ramp — warm greys in light (subscription mock), cool blue-greys in dark (Bedrock mock).
    static let ink   = dynamic(light: 0x1C1D22, dark: 0xEEF0F4)
    static let muted = dynamic(light: 0x76736D, dark: 0x9AA1B1)
    static let faint = dynamic(light: 0xA29E97, dark: 0x73798A)
    static let onAccent = Color(hex8: 0x0C0E13)   // dark text that reads on a green fill in either mode

    // Structure.
    static let track      = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.05)
    static let hairline   = Color.primary.opacity(0.10)

    /// The panel's inner edge highlight — a bright thin line in light, a faint white in dark.
    static func panelStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.65)
    }
    /// Inset card fill (burn-rate box, etc.) — subtle in both appearances.
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
    }
    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    // Numeric figures: tabular so digits don't jitter as they tick.
    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Optical tracking for big figures (design uses ≈ -.02em); points scale with size.
    static func tightTracking(_ size: CGFloat) -> CGFloat { -size * 0.02 }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
