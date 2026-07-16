// Token Tab — pure parser for the opt-in live usage window (Swift port of
// ../../src/live-parse.mjs).
//
// PURE: no I/O, no subprocess, no network. Takes the raw stdout of
// `claude -p "/usage" --output-format json` and returns the server-side
// session/weekly percentages, or nil on anything unexpected (fail closed).
//
// This lives in TokenTabCore (the audited pure-model half of the app, alongside
// Core.swift); the live adapter that produces its input lives elsewhere. Keeping this
// file free of subprocess and network calls is the whole point — the audit greps must
// keep printing nothing, so this file avoids those tokens even in comments.
//
// Robustness notes (each pins a real failure mode, see LiveParseTests.swift):
//  - The percentage is matched INDEPENDENTLY of the "· resets …" tail, so a
//    future separator/encoding change (the `·` is U+00B7) costs only the reset
//    text, never the number the feature exists to show.
//  - We split on "\n" and match per line; a single anchored regex against the
//    whole multi-line result string would never match.
//  - The whole body is guarded so parseUsageOutput(nil) returns nil, never throws.
import Foundation

// MARK: - LiveParse

public enum LiveParse {
    /// The server-side rate-limit reading parsed from `claude /usage` output. Every
    /// field is optional because the CLI's prose drifts; we fail soft to whatever parsed.
    public struct Reading: Sendable, Equatable {
        public var sessionPct: Int?
        public var sessionResetText: String?
        public var weeklyPct: Int?
        public var weeklyResetText: String?
        public var weeklyByModel: [String: Int]

        public init(sessionPct: Int? = nil, sessionResetText: String? = nil,
                    weeklyPct: Int? = nil, weeklyResetText: String? = nil,
                    weeklyByModel: [String: Int] = [:]) {
            self.sessionPct = sessionPct
            self.sessionResetText = sessionResetText
            self.weeklyPct = weeklyPct
            self.weeklyResetText = weeklyResetText
            self.weeklyByModel = weeklyByModel
        }
    }

    // Per-line: "Current session: 7% used …" / "Current week (all models): 8% used …" /
    // "Current week (Sonnet only): 0% used …". The reset tail is NOT captured here — it's
    // parsed independently below so a separator/wording drift can't cost the percentage.
    private static let pctRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^Current (session|week \\(([^)]+)\\)):\\s*(\\d+)%\\s*used\\b(.*)$")
    }()

    // Applied only to the tail captured after "used" — independent of the percent match.
    private static let resetRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "resets\\s+(.+?)\\s*$")
    }()

    /// Parse the raw stdout of `claude -p "/usage" --output-format json`. Returns nil on
    /// any parse failure, a non-object/null envelope, `is_error == true`, a non-string
    /// result, or when no "Current …% used" line is found anywhere in the result text.
    public static func parseUsageOutput(_ stdout: String?) -> Reading? {
        guard let stdout else { return nil }
        guard let data = stdout.data(using: .utf8) else { return nil }

        let envelope: Any
        do {
            envelope = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return nil // non-JSON stdout (e.g. "command not found")
        }

        guard let obj = envelope as? [String: Any] else { return nil }
        if let isError = obj["is_error"] as? Bool, isError == true { return nil }
        guard let result = obj["result"] as? String else { return nil }

        var sessionPct: Int?
        var sessionResetText: String?
        var weeklyPct: Int?
        var weeklyResetText: String?
        var weeklyByModel: [String: Int] = [:]
        var found = false

        for rawLine in result.components(separatedBy: "\n") {
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() } // tolerate CRLF

            let lineStr = String(line)
            let full = NSRange(lineStr.startIndex..., in: lineStr)
            guard let m = pctRegex.firstMatch(in: lineStr, range: full) else { continue }

            let kind = substring(lineStr, m.range(at: 1))
            let inner = m.range(at: 2).location == NSNotFound ? nil : substring(lineStr, m.range(at: 2))
            guard let kind, let pctStr = substring(lineStr, m.range(at: 3)), let pct = Int(pctStr) else { continue }
            let tail = m.range(at: 4).location == NSNotFound ? "" : (substring(lineStr, m.range(at: 4)) ?? "")

            let resetText: String?
            let tailRange = NSRange(tail.startIndex..., in: tail)
            if let rm = resetRegex.firstMatch(in: tail, range: tailRange) {
                resetText = substring(tail, rm.range(at: 1))
            } else {
                resetText = nil
            }

            if kind == "session" {
                sessionPct = pct
                sessionResetText = resetText
                found = true
            } else {
                let label = (inner ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if label == "all models" {
                    weeklyPct = pct
                    weeklyResetText = resetText
                    found = true
                } else {
                    // Mirror the JS `/\s+only$/` (any run of whitespace), not just " only".
                    var stripped = label
                    if let r = stripped.range(of: "\\s+only$", options: .regularExpression) {
                        stripped.removeSubrange(r)
                    }
                    weeklyByModel[stripped] = pct
                    found = true
                }
            }
        }

        guard found else { return nil } // no "Current …% used" line anywhere
        return Reading(sessionPct: sessionPct, sessionResetText: sessionResetText,
                       weeklyPct: weeklyPct, weeklyResetText: weeklyResetText,
                       weeklyByModel: weeklyByModel)
    }

    /// Extract the substring for an NSRange (as produced against `s`), or nil when the
    /// range didn't participate in the match.
    private static func substring(_ s: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let r = Range(range, in: s) else { return nil }
        return String(s[r])
    }
}
