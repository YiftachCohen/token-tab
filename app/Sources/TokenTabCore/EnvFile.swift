// Token Tab — the local KEY=VALUE dotfile parser, shared by the app and the live helper.
//
// PURE: string in, dictionary out — no I/O. Hoisted out of the app's Config so the
// bundled TokenTabLiveHelper honors the exact same dotfile syntax (~/.config/token-tab/env
// et al.) without a second hand-kept parser. Mirrors the JS regex in token-tab.mjs
// loadLocalConfig(): tolerant of CRLF, strips one layer of matching quotes, first line
// wins per key, and only TOKENTAB_* keys (plus CLAUDE_CODE_USE_BEDROCK) are honored.

public enum EnvFile {
    public static func parse(_ text: String) -> [String: String] {
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
}
