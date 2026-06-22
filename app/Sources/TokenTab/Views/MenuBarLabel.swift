// Token Tab — the menu-bar glyph.
//
// The readability study's "Recommended" treatment: a monochrome number (always legible
// on any wallpaper, light or dark — the system tints the text to match the bar) plus a
// single colored health dot, the one signal worth spending color on. What the number
// says is decided by the active mode, not a toggle:
//   • Subscription → runway: "{remaining}%" of the window when a cap is set, else the
//     exact time left ("1h52") — never a guessed %.
//   • Burn (Bedrock/API) → "$5.10" or "22.9M" today, per the menu-bar metric toggle.

import SwiftUI
import TokenTabCore

struct MenuBarLabel: View {
    let snapshot: Snapshot
    let menuMetric: MenuMetric

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snapshot.health.color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    private var text: String {
        switch snapshot.mode {
        case .subscription:
            if let used = snapshot.agg.window.tokenPct {
                return "\(max(0, 100 - used))%"
            }
            // No cap → show exact time left (honest; no invented %).
            let secs = snapshot.agg.window.secondsToReset(now: Date())
            return snapshot.agg.window.active ? Fmt.durationCompact(secs) : "—"
        case .burn:
            switch menuMetric {
            case .cost:   return Fmt.usd(snapshot.agg.cost?.today ?? 0)
            case .tokens: return Fmt.millions(snapshot.agg.today)
            }
        }
    }
}
