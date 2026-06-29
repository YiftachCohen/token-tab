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

/// Which tab the dropdown is showing — the design's "Overview | History" switcher.
enum PanelTab: Hashable { case overview, history }

/// The "Overview | History" tab switcher under the header. A raised white chip marks the
/// active tab (design's `--tabOn`), distinct from the green-fill segmented controls below.
struct PanelTabBar: View {
    @Binding var selection: PanelTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            tab("Overview", .overview)
            tab("History", .history)
        }
        .padding(2)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tab(_ title: String, _ value: PanelTab) -> some View {
        let on = selection == value
        return Text(title)
            .font(.system(size: 11.5, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.ink : Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(on ? Theme.tabOn(scheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: on ? Color.black.opacity(0.10) : .clear, radius: 1.5, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { selection = value } }
    }
}

/// A compact green-fill segmented control (design's `segOn`/`segOff`) — the History tab's
/// "$ / Tok" metric and "7d / 14d / 30d" range pickers. The selected segment fills green
/// with dark-on-green text; the rest are muted on a faint pill track.
struct MiniSegmented<T: Hashable>: View {
    var options: [(label: String, value: T)]
    @Binding var selection: T
    var hPadding: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                seg(options[i].label, options[i].value)
            }
        }
        .padding(2)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func seg(_ label: String, _ value: T) -> some View {
        let on = selection == value
        return Text(label)
            .font(.system(size: 10.5, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.onAccent : Theme.muted)
            .padding(.vertical, 3).padding(.horizontal, hPadding)
            .background(on ? Theme.green : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
    }
}

/// The History "↑ 28% vs prev" / "↓ 9% vs prev" badge. Up is amber (spending more), down is
/// green (spending less) — matching the design's `deltaStyle`.
struct DeltaBadge: View {
    var deltaPct: Int
    private var up: Bool { deltaPct > 0 }
    private var tint: Color { up ? Theme.amber : Theme.green }

    var body: some View {
        Text("\(up ? "↑" : "↓") \(abs(deltaPct))% vs prev")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(tint.opacity(0.16), in: Capsule())
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
