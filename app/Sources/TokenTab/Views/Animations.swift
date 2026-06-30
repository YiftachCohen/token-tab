// Token Tab — the "open beat".
//
// One motion idea, applied wherever a number is worth watching arrive: when the dropdown
// opens, the gauge sweeps, the dollar/percent counts up, and the History bars grow from the
// baseline. Ease-out, no bounce — "precision waking up", not a cartoon. The whole beat tunes
// from one place (OpenBeat.duration), so it's trivial to slow, speed, or disable.

import SwiftUI

enum OpenBeat {
    /// The open-beat duration. Live data changes mid-session reuse it, so numbers glide
    /// rather than jump. Set to 0 to turn the beat off everywhere.
    static let duration: Double = 0.6
}

/// A figure that counts from 0 to `target` on appear (and glides to later values as data
/// refreshes). SwiftUI `Text` can't interpolate a value, so the number rides `animatableData`
/// and the formatter re-renders each eased frame. If the beat is disabled or never fires, the
/// final value still shows correctly — `started` simply pins it to `target`.
struct AnimatedNumber: View {
    var target: Double
    var font: Font
    var tracking: CGFloat = 0
    var color: Color = Theme.ink
    var format: (Double) -> String

    @State private var started = false

    var body: some View {
        let value = started ? target : 0
        Text(verbatim: "")
            .modifier(CountingText(value: value, format: format))
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .animation(.easeOut(duration: OpenBeat.duration), value: value)
            .onAppear { started = true }
    }
}

/// Drives the interpolation: `value` is the animatable channel; `body` formats it each frame.
private struct CountingText: AnimatableModifier {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    let format: (Double) -> String

    func body(content: Content) -> some View {
        Text(format(value))
    }
}
