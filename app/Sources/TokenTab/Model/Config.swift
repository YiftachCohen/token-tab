// Token Tab — machine-local settings (mirrors loadLocalConfig in token-tab.mjs).
//
// Reads TOKENTAB_* keys from the environment, or from a KEY=VALUE file kept OUTSIDE the
// repo (~/.config/token-tab/env or ~/.token-tab.env) so your plan cap never gets
// committed. Real env vars win. Only TOKENTAB_* keys are honored. Reads a local file
// only — no network, no secrets.

import Foundation
import TokenTabCore

enum Config {
    private static func loadFileValues() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".config/token-tab/env"),
            home.appendingPathComponent(".token-tab.env"),
        ]
        var values: [String: String] = [:]
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let s = String(line)
                guard let eq = s.firstIndex(of: "=") else { continue }
                let key = s[..<eq].trimmingCharacters(in: .whitespaces)
                guard key.hasPrefix("TOKENTAB_") else { continue }
                var val = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                if values[key] == nil { values[key] = val }
            }
        }
        return values
    }

    static func string(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v } // real env wins
        return loadFileValues()[key]
    }

    /// The plan's 5h token cap (TOKENTAB_WINDOW_CAP), to show a window %. 0 if unset —
    /// we never invent a cap, so without this no guessed % is shown.
    static var windowCap: Int {
        guard let v = string("TOKENTAB_WINDOW_CAP"), let n = Int(v), n > 0 else { return 0 }
        return n
    }

    /// Force the displayed surface (TOKENTAB_MODE), overriding model-id auto-detection.
    /// Needed because Claude Code on Bedrock logs bare `claude-*` ids with no `us.anthropic.`
    /// prefix — so auto-detection (classifySurface) sees only subscription. Returns nil to
    /// keep auto-detection. Accepts: bedrock | subscription (max/pro) | payg (pay-per-token/api).
    static var surfaceOverride: Surface? {
        guard let v = string("TOKENTAB_MODE")?.lowercased() else { return nil }
        switch v {
        case "bedrock": return .bedrock
        case "subscription", "max", "pro", "sub": return .subscription
        case "payg", "pay-per-token", "paypertoken", "api", "untracked": return .untracked
        default: return nil
        }
    }
}
