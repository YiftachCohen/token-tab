// Token Tab — reusable building blocks for the dropdown, matching the design's
// gauge / bars / segmented control.

import SwiftUI

/// The brand gauge: a faint track ring with a green arc. Used in the panel header
/// (small) and the subscription hero (large, with center content).
struct BrandMark: View {
    var size: CGFloat
    var lineWidth: CGFloat
    var fraction: Double = 0.63        // arc sweep (logo default matches the mock)
    var color: Color = Theme.green
    var trackOpacity: Double = 0.0     // header glyph has no visible track

    var body: some View {
        ZStack {
            if trackOpacity > 0 {
                Circle().stroke(Color.primary.opacity(trackOpacity), lineWidth: lineWidth)
            }
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Large progress ring with arbitrary center content (the subscription runway hero).
struct RingGauge<Center: View>: View {
    var fraction: Double
    var size: CGFloat
    var lineWidth: CGFloat
    var color: Color
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
            center()
        }
        .frame(width: size, height: size)
    }
}

/// A thin rounded progress bar. Optionally a two-segment bar (solid main + faded sub),
/// matching the design's "solid = main · faded = sub".
struct MiniBar: View {
    var fraction: Double                 // primary fill (0...1)
    var subFraction: Double? = nil       // optional faded segment appended after primary
    var color: Color = Theme.green
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                HStack(spacing: 1.5) {
                    Capsule().fill(color)
                        .frame(width: max(0, min(1, fraction)) * w)
                    if let sub = subFraction {
                        Capsule().fill(color.opacity(0.32))
                            .frame(width: max(0, min(1, sub)) * w)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Small uppercase section label (#a8a49d / .04em tracking in the mock).
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.faint)
    }
}

/// The "MENU BAR SHOWS  [ $ cost | Tokens ]" segmented control.
struct SegmentedToggle: View {
    @Binding var selection: MenuMetric

    var body: some View {
        HStack(spacing: 2) {
            seg("$ cost", .cost)
            seg("Tokens", .tokens)
        }
        .padding(2)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func seg(_ title: String, _ value: MenuMetric) -> some View {
        let on = selection == value
        return Text(title)
            .font(.system(size: 11, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.onAccent : Theme.muted)
            .padding(.vertical, 4).padding(.horizontal, 13)
            .background(on ? Theme.green : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: on ? Theme.green.opacity(0.35) : .clear, radius: 4, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
    }
}

/// A capsule "pill" badge like CLAUDE MAX / BEDROCK in the header.
struct Pill: View {
    var text: String
    var tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.vertical, 3).padding(.horizontal, 9)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

/// A small accent dot with a soft glow (health dot, live indicator, trust dot).
struct GlowDot: View {
    var color: Color
    var size: CGFloat = 6
    var glow: CGFloat = 4
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: glow)
    }
}

/// Footer trust line with a green dot (matches "Local only — nothing leaves this Mac").
struct TrustFooter: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            GlowDot(color: Theme.green)
            Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Inset card chrome (subtle fill + hairline), adaptive to appearance.
struct Card: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.cardStroke(scheme), lineWidth: 0.5))
    }
}
extension View {
    func card(radius: CGFloat = 10) -> some View { modifier(Card(radius: radius)) }
}

/// Themed text-field chrome (replaces the stock `.roundedBorder`, which read foreign on the dark
/// glass): a subtle fill + hairline, with a green ring when focused. Pair with
/// `.textFieldStyle(.plain)` and a `@FocusState` passed in via `focused`, so the cap inputs match
/// the panel in both appearances.
struct TokenFieldChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Theme.green.opacity(0.7) : Theme.cardStroke(scheme),
                              lineWidth: focused ? 1 : 0.75))
    }
}
extension View {
    func tokenFieldChrome(focused: Bool) -> some View { modifier(TokenFieldChrome(focused: focused)) }
}
