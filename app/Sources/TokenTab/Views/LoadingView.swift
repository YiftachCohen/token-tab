// Token Tab — the loading state.
//
// A short, on-brand moment: the app's ring gauge "scans" the logs (a green comet orbiting a
// faint track inside a breathing aura) while a token tally ROLLS UP in the center like an
// odometer — because that is literally what the app is doing, counting the tokens in your
// logs. The status line narrates the work and cycles, each line fading at its edges so swaps
// are never a hard cut, and a faint trust line reassures that nothing leaves the Mac while it
// reads. Honors Reduce Motion (static arc, no rolling) and adapts to light/dark via Theme.

import SwiftUI
import TokenTabCore

struct LoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// When this loader came on screen — the tally climbs from zero relative to it, so the
    /// count starts where the read starts instead of mid-roll at an arbitrary clock phase.
    @State private var start = Date()

    /// The app narrating its work — cycles while the logs are read.
    private let lines = ["Reading ~/.claude…", "Counting tokens…", "Tallying the week…", "Almost there…"]

    var body: some View {
        Group {
            if reduceMotion {
                // Static: a calm arc + the lines. No motion, no rolling tally.
                content(rotation: 0, sweep: 0.30, breath: 0.5, tally: nil, line: lines[0], lineOpacity: 1)
            } else {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let rotation = (t.truncatingRemainder(dividingBy: 1.4) / 1.4) * 360
                    let breath = 0.5 + 0.5 * sin(t * 2.7)        // 0…1, organic pulse
                    let sweep = 0.12 + 0.46 * breath             // comet length

                    // Narration cycles; each line fades in over its first slice and out over its
                    // last, so the text swaps while invisible (no hard cut).
                    let cycle = 1.6
                    let idx = Int(t / cycle) % lines.count
                    let local = (t.truncatingRemainder(dividingBy: cycle)) / cycle
                    let lineOpacity = min(1, min(local, 1 - local) * 7)

                    content(rotation: rotation, sweep: sweep, breath: breath,
                            tally: RollingTally.value(at: ctx.date.timeIntervalSince(start)),
                            line: lines[idx], lineOpacity: lineOpacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { appeared = true } }
        }
    }

    private func content(rotation: Double, sweep: Double, breath: Double,
                         tally: Int?, line: String, lineOpacity: Double) -> some View {
        VStack(spacing: 30) {
            ScanningGauge(rotation: rotation, sweep: sweep, breath: breath, tally: tally)
            VStack(spacing: 7) {
                Text(line)
                    .font(.system(size: 12, weight: .medium)).tracking(0.2)
                    .foregroundStyle(Theme.muted)
                    .opacity(lineOpacity)
                TrustFooter(text: "Local only — nothing leaves this Mac")
            }
        }
    }
}

/// A gauge that "scans": faint track ring + a green comet arc (fades tail→head) over a breathing
/// aura, with a token tally rolling up in the center. Same ring vocabulary as the runway hero, in
/// motion — so the loader rhymes with the panel it becomes.
private struct ScanningGauge: View {
    var rotation: Double
    var sweep: Double
    var breath: Double
    /// The tally to show in the center, or nil under Reduce Motion.
    var tally: Int?
    var size: CGFloat = 50
    var lineWidth: CGFloat = 3.5

    var body: some View {
        ZStack {
            // Soft aura that breathes outward — depth, matching the GlowDot glow language.
            Circle()
                .fill(RadialGradient(colors: [Theme.green.opacity(0.30), .clear],
                                     center: .center, startRadius: 1, endRadius: size * 0.5))
                .frame(width: size * 1.5, height: size * 1.5)
                .scaleEffect(0.82 + 0.24 * breath)
                .blur(radius: 3)

            // The gauge track.
            Circle().stroke(Theme.track, lineWidth: lineWidth)

            // The comet: transparent tail → bright head, orbiting with a green glow.
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Theme.green.opacity(0.0), location: 0.0),
                            .init(color: Theme.green.opacity(0.9), location: sweep * 0.9),
                            .init(color: Theme.green, location: sweep),
                        ]),
                        center: .center,
                        startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90 + rotation))
                .shadow(color: Theme.green.opacity(0.4), radius: 2.5)

            // Center: the token tally, rolling up like an odometer (absent under Reduce Motion).
            if let tally {
                RollingTally(value: tally)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The center figure: a token count that climbs toward ~188M in decelerating steps and loops,
/// each step rolling its digits via `.numericText()`. The value is a pure function of the
/// enclosing `TimelineView`'s clock — a self-owned `Timer` would be re-created and re-subscribed
/// by every 60fps re-render of that timeline, restarting its interval before it could ever fire,
/// so the tally sat at 0 for the whole load.
private struct RollingTally: View {
    var value: Int

    var body: some View {
        Text(Fmt.abbrev(value))
            .font(Theme.figure(14, weight: .semibold))
            .foregroundStyle(Theme.green)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.18), value: value)
    }

    /// One step every 110ms — fast enough to read as an odometer, slow enough to see the digits.
    private static let interval = 0.11

    /// Ease-out climb: each step covers a fraction of the remaining distance, so the digits roll
    /// fast at first and settle near the top before the sequence loops back to zero (~2.2s).
    private static let steps: [Int] = {
        var out = [0]
        var v = 0
        while true {
            v += max(2_000_000, (200_000_000 - v) / 7)
            if v >= 188_000_000 { return out }
            out.append(v)
        }
    }()

    /// `elapsed` is seconds since the loader appeared; clamped so a frame timestamped a hair
    /// before that can't index backwards off the front of the sequence.
    static func value(at elapsed: TimeInterval) -> Int {
        steps[Int(max(0, elapsed) / interval) % steps.count]
    }
}
