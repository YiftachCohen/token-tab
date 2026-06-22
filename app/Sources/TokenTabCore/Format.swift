// Token Tab — display formatting (ported from the JS renderer's abbrev/fmtDur/fmtUsd).
// Pure string math, kept in the core so the menu-bar label and dropdown render
// identically and the rules are unit-tested.

import Foundation

public enum Fmt {
    /// 1234 -> "1.2K", 22_938_204 -> "22.9M", 1_500_000_000 -> "1.50B".
    public static func abbrev(_ n: Int) -> String {
        let v = Double(n)
        if n < 1_000 { return String(n) }
        if n < 1_000_000 { return trimmed(v / 1_000, decimals: n < 10_000 ? 1 : 0) + "K" }
        if n < 1_000_000_000 { return trimmed(v / 1_000_000, decimals: n < 10_000_000 ? 1 : 0) + "M" }
        return trimmed(v / 1_000_000_000, decimals: 2) + "B"
    }

    /// Tokens as "22.9M" — always one decimal in millions, matching the design's hero.
    public static func millions(_ n: Int) -> String {
        trimmed(Double(n) / 1_000_000, decimals: 1) + "M"
    }

    /// Full grouped integer: 22_938_204 -> "22,938,204".
    public static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Duration from seconds -> "1h 52m" / "47m". nil/negative -> "—".
    public static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s >= 0 else { return "—" }
        let mins = Int((s / 60).rounded())
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Compact duration for the menu bar: "1h52" / "47m".
    public static func durationCompact(_ seconds: Double?) -> String {
        guard let s = seconds, s >= 0 else { return "—" }
        let mins = Int((s / 60).rounded())
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)m"
    }

    /// Dollars: cents under $1k, whole dollars above. Tiny nonzero spend -> "<$0.01".
    public static func usd(_ n: Double) -> String {
        if n <= 0 { return "$0.00" }
        if n < 0.01 { return "<$0.01" }
        if n >= 1000 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: n.rounded())) ?? String(Int(n)))
        }
        return "$" + String(format: "%.2f", n)
    }

    /// Reset clock time like the design's "resets 11:33" (local time, 24h or 12h per locale).
    public static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private static func trimmed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
