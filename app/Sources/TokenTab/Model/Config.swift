// Token Tab — machine-local settings (mirrors loadLocalConfig in token-tab.mjs).
//
// Reads TOKENTAB_* keys from the environment, or from a KEY=VALUE file kept OUTSIDE the
// repo ($TOKENTAB_CONFIG, then ~/.config/token-tab/env or ~/.token-tab.env) so your plan
// cap never gets committed. Real env vars win. Only TOKENTAB_* keys are honored — plus Claude Code's
// own CLAUDE_CODE_USE_BEDROCK, which forces the Bedrock panel (see `useBedrock`): a
// sandboxed GUI app won't inherit your shell env, so it has to be settable in the file
// too. Reads a local file only — no network, no secrets.

import Foundation
import TokenTabCore

enum Config {
    /// The local dotfile values, parsed ONCE per process (matches the JS engine, which
    /// reads ~/.config/token-tab/env once at startup via loadLocalConfig()). Real env vars
    /// still take precedence and are read live in `string(_:)`. Reads a local file only —
    /// no network, no subprocess.
    private static let fileValues: [String: String] = loadFileValues()

    private static func loadFileValues() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Candidate order mirrors the JS engine's loadLocalConfig(): $TOKENTAB_CONFIG first
        // (read straight from the process env — NOT via string(_:), which would recurse into
        // fileValues), then the two default dotfile paths. A leading tilde is expanded the same
        // way LogReader.defaultLogDir() does.
        var candidates: [URL] = []
        if let cfg = ProcessInfo.processInfo.environment["TOKENTAB_CONFIG"], !cfg.isEmpty {
            candidates.append(URL(fileURLWithPath: (cfg as NSString).expandingTildeInPath))
        }
        candidates.append(home.appendingPathComponent(".config/token-tab/env"))
        candidates.append(home.appendingPathComponent(".token-tab.env"))
        var values: [String: String] = [:]
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // First file (and first line) wins per key, matching the JS `!(m[1] in process.env)` guard.
            for (key, val) in parseEnvFile(text) where values[key] == nil {
                values[key] = val
            }
        }
        return values
    }

    /// Parse one env-file's text into the honored KEY=VALUE pairs. Internal (not
    /// private) so tests can pin CRLF/quoting behavior without touching $HOME.
    /// Mirrors the JS regex in token-tab.mjs loadLocalConfig(): tolerant of CRLF
    /// (the JS `\s*$` eats the trailing \r), strips one layer of matching quotes.
    static func parseEnvFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        // Split on any newline (\r, \n, \r\n) so a CRLF file yields clean lines with no
        // trailing \r — otherwise Int("400000000\r") is nil and "bedrock\r" matches no case.
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("TOKENTAB_") || key == "CLAUDE_CODE_USE_BEDROCK" else { continue }
            var val = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if values[key] == nil { values[key] = val }
        }
        return values
    }

    static func string(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v } // real env wins
        return fileValues[key]   // cached; no longer re-reads disk per call
    }

    /// The plan's 5h token cap (TOKENTAB_WINDOW_CAP), to show a window %. 0 if unset —
    /// we never invent a cap, so without this no guessed % is shown.
    static var windowCap: Int {
        guard let v = string("TOKENTAB_WINDOW_CAP"), let n = Int(v), n > 0 else { return 0 }
        return n
    }

    /// Absolute path to the repo's `adapters/` dir, so the "turn on live" help can hand over
    /// a command that runs from ANY directory (no `cd` into the Token Tab folder first). The
    /// app can't run the helper itself — sandboxed, no network — so the most we can do is make
    /// the copied command paste-and-run. Returns nil if the folder can't be located, in which
    /// case the UI falls back to the relative command.
    static func adaptersDir() -> URL? {
        let bundle = Bundle.main.bundleURL
        // Sandboxed .app: it lives at <repo>/app/Token Tab.app, so adapters is two levels up.
        // Pure path math — the sandbox can't stat outside ~/.claude, so we don't probe disk.
        if bundle.pathExtension == "app" {
            return bundle.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("adapters")
        }
        // Dev (`swift run`, unsandboxed): walk up to the dir that holds adapters/install-live.sh.
        var dir = bundle
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("adapters/install-live.sh").path) {
                return dir.appendingPathComponent("adapters")
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The providers to ingest, from TOKENTAB_PROVIDERS (comma list, `all` accepted). Returns
    /// nil for "no explicit setting" so the caller can default to "every provider whose dir
    /// exists" (a missing dir is silently skipped, never an error — mirrors the JS engine).
    /// Unknown tokens are ignored; an empty/whitespace value is treated as unset.
    static func providers() -> Set<String>? {
        guard let raw = string("TOKENTAB_PROVIDERS")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if parts.contains("all") { return nil }   // "all" == default (no gating)
        let set = Set(parts.filter { !$0.isEmpty })
        return set.isEmpty ? nil : set
    }

    /// Whether a given provider is enabled. `dirExists` gates the default case: with no explicit
    /// TOKENTAB_PROVIDERS, a provider is on iff its log dir exists (silently off otherwise).
    /// An explicit list turns a provider on regardless of dir existence (the reader then just
    /// finds no files) — the whitelist is intent, not a filesystem probe.
    static func providerEnabled(_ name: String, dirExists: Bool) -> Bool {
        if let allow = providers() { return allow.contains(name.lowercased()) }
        return dirExists
    }

    /// Force the pay-per-token (Bedrock) panel when Claude Code's CLAUDE_CODE_USE_BEDROCK
    /// flag is truthy. Bedrock can't be told apart from a subscription by the logs alone —
    /// on Bedrock, Claude Code writes bare `claude-*` model ids that classifySurface reads
    /// as `.subscription` — so we trust the same flag that put Claude Code on Bedrock in the
    /// first place. Works as a real env var, or in the local env file for the GUI app.
    static var useBedrock: Bool {
        guard let v = string("CLAUDE_CODE_USE_BEDROCK")?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    /// Force the displayed surface (TOKENTAB_MODE), overriding model-id auto-detection.
    /// Needed because Claude Code on Bedrock logs bare `claude-*` ids with no `us.anthropic.`
    /// prefix — so auto-detection (classifySurface) sees only subscription. Returns nil to
    /// keep auto-detection. Accepts: bedrock | subscription (max/pro) | payg (pay-per-token/api).
    /// Takes precedence over `useBedrock`: an explicit mode beats the inferred Bedrock flag.
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
