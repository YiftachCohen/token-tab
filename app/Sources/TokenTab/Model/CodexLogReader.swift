// Token Tab — Codex ingestion reader (Swift port of src/codex.mjs).
//
// Codex (OpenAI CLI) writes JSONL rollout logs under ~/.codex/sessions and
// ~/.codex/archived_sessions. Unlike Claude's per-message usage, Codex logs a
// `token_count` event whose `total_token_usage` is CUMULATIVE per session — and
// (verified on real logs) resets mid-file on compaction and emits duplicate
// pairs. So we can't sum; we fold deltas per token class with an independent
// reset guard per class. See .context/codex-support-design.md §2 and src/codex.mjs
// (the reference implementation this mirrors exactly).
//
// TRUST BOUNDARY, in two layers (mirroring src/codex.mjs):
//   1. `topLevelType` reads each line's top-level `type` off the RAW STRING and drops
//      anything outside the whitelist before the decoder ever sees it — so a
//      `response_item` line's prompt/response text is never decoded or allocated.
//   2. The Decodable structs below physically contain ONLY the whitelisted
//      numeric/metadata fields (same pattern as LogReader.Line): there is no field for
//      `response_item` content, session_meta.instructions, or cwd, so even a line that
//      passes layer 1 has no code path that could surface your prompts/code.
// No network, ever.

import Foundation
import TokenTabCore

enum CodexLogReader {
    /// Codex root dir: $TOKENTAB_CODEX_LOG_DIR > $CODEX_HOME > ~/.codex.
    /// This is the ROOT — `sessions/` and `archived_sessions/` are subdirs.
    /// Reads via Config so the env/dotfile precedence matches the JS engine (a
    /// sandboxed GUI app won't inherit the shell env, so a dotfile must work too).
    static func defaultCodexRoot() -> URL {
        if let d = Config.string("TOKENTAB_CODEX_LOG_DIR"), !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        }
        if let c = Config.string("CODEX_HOME"), !c.isEmpty {
            return URL(fileURLWithPath: (c as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Walk sessions/** + archived_sessions/*.jsonl under `root`, oldest mtime first
    /// (then path) so first-seen order is reproducible — same convention as the JS
    /// findCodexJsonl and LogReader.findJSONL. Tolerates missing subdirs / vanishing files.
    static func findCodexJSONL(in root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [(url: URL, mtime: Date)] = []
        for sub in ["sessions", "archived_sessions"] {
            let dir = root.appendingPathComponent(sub)
            guard let en = fm.enumerator(at: dir,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: []) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                out.append((url, vals?.contentModificationDate ?? .distantPast))
            }
        }
        return out.sorted {
            $0.mtime != $1.mtime ? $0.mtime < $1.mtime : $0.url.path < $1.url.path
        }.map(\.url)
    }

    // uuid embedded in `rollout-<ts>-<uuid>.jsonl`. The <ts> also contains dashes,
    // so anchor on the trailing 8-4-4-4-12 uuid before the extension.
    private static let uuidRE = try! NSRegularExpression(
        pattern: "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.jsonl$",
        options: [.caseInsensitive])

    private static func uuidFromFileName(_ fileName: String?) -> String? {
        guard let fileName else { return nil }
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let m = uuidRE.firstMatch(in: fileName, range: range),
              let r = Range(m.range(at: 1), in: fileName) else { return nil }
        return String(fileName[r])
    }

    /// The only three top-level `type` values we ever decode. Everything else — above all
    /// `response_item`, the line that carries your prompts, responses and reasoning — is
    /// dropped as an undecoded string. Mirrors DECODED_TYPES in src/codex.mjs.
    private static let decodedTypes: Set<String> = ["session_meta", "turn_context", "event_msg"]

    /// The characters a type token may contain — the Swift twin of TOP_TYPE_RE's char class.
    private static let typeTokenChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    /// Read a line's top-level `type` WITHOUT decoding the line — the content gate.
    ///
    /// Codex writes the envelope keys (`timestamp`, `type`, `payload`) before the payload, so
    /// the first `"type": "..."` in the string IS the top-level one. Returns nil when the line
    /// carries no such key at all; the caller then falls through to the decoder, so a genuinely
    /// malformed line is still counted rather than silently dropped. If a nested field ever
    /// matched first, the worst case is decoding a line we would have skipped — the `obj.type`
    /// switch still refuses to read it — so this only fails toward the old behavior, never
    /// toward surfacing content. Mirrors TOP_TYPE_RE in src/codex.mjs.
    static func topLevelType(of line: String) -> String? {
        var from = line.startIndex
        while let key = line.range(of: "\"type\"", range: from..<line.endIndex) {
            from = key.upperBound
            if let value = quotedToken(in: line, after: key.upperBound) { return value }
        }
        return nil
    }

    /// `: "token"` immediately after `idx` (whitespace-tolerant), where token is non-empty and
    /// made only of `typeTokenChars`. nil when the shape doesn't match, so the caller keeps
    /// scanning — the same way the JS regex skips a non-matching candidate.
    private static func quotedToken(in s: String, after idx: String.Index) -> String? {
        var i = idx
        func skipSpaces() {
            while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
        }
        skipSpaces()
        guard i < s.endIndex, s[i] == ":" else { return nil }
        i = s.index(after: i)
        skipSpaces()
        guard i < s.endIndex, s[i] == "\"" else { return nil }
        i = s.index(after: i)
        var token = ""
        while i < s.endIndex, s[i] != "\"" {
            guard typeTokenChars.contains(s[i]) else { return nil }
            token.append(s[i])
            i = s.index(after: i)
        }
        guard i < s.endIndex, !token.isEmpty else { return nil }
        return token
    }

    /// The whitelisted fields of one JSONL line. No content field exists here on purpose.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?      // event_msg subtype ("token_count", …)
            let id: String?        // session_meta.payload.id
            let model: String?     // turn_context.payload.model
            let info: Info?        // token_count.payload.info (occasionally null)
            let rate_limits: RateLimits?
        }
        struct Info: Decodable {
            let total_token_usage: TotalTokenUsage?
        }
        struct TotalTokenUsage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
        }
        struct RateLimits: Decodable {
            let primary: Window?
            let secondary: Window?
            let plan_type: String?
            struct Window: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?   // epoch seconds in real logs (may be absent)
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// The result of folding one file: records + malformed count + the file's latest
    /// rate_limits snapshot (display data only, never summed).
    struct FileResult {
        var records: [UsageRecord]
        var malformed: Int
        var rateLimits: CodexRateLimitsSnapshot?
    }

    /// The carry between two parses of the SAME file — everything the per-file fold tracks
    /// across lines. A Codex file can't be tail-parsed statelessly the way a Claude one can:
    /// `total_token_usage` is cumulative, so resuming without the baselines would recount the
    /// whole session as one giant delta (and lose the session id / current model the earlier
    /// lines established). RecordCache stores one of these per Codex file and hands it back
    /// for the appended tail. A fresh `FoldState()` + whole file ≡ the old one-shot fold.
    struct FoldState: Sendable {
        // Per-class running baselines. total_tokens is NEVER used for arithmetic.
        var prevInput = 0, prevCached = 0, prevOutput = 0
        var sessionId: String? = nil
        var currentModel: String? = nil
        var seq = 0
        var rateLimits: CodexRateLimitsSnapshot? = nil   // file's latest, by asOf
        init() {}
    }

    /// Pure per-file fold (spec §2). Takes the file's lines and returns the emitted
    /// UsageRecords (provider "codex") plus the latest rate_limits snapshot. Kept pure
    /// (lines-in) so it is trivially fixture-testable, exactly like recordsFromCodexLines.
    static func recordsFromLines(_ lines: [String], fileName: String?) -> FileResult {
        var state = FoldState()
        let (records, malformed) = fold(lines, fileName: fileName, state: &state)
        return FileResult(records: records, malformed: malformed, rateLimits: state.rateLimits)
    }

    /// The fold itself, resumable: consumes `lines` continuing from (and advancing) `state`.
    static func fold(_ lines: [String], fileName: String?,
                     state: inout FoldState) -> (records: [UsageRecord], malformed: Int) {
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        for rawLine in lines {
            foldLine(rawLine, fileName: fileName, decoder: decoder,
                     state: &state, records: &records, malformed: &malformed)
        }
        return (records, malformed)
    }

    /// One line of the fold — the unit the array driver above and the streaming `parseComplete`
    /// share, so the memory-bound path can parse each line during the byte scan without ever
    /// collecting the file's decoded text (which, pre-gate, includes `response_item` content).
    private static func foldLine(_ rawLine: String, fileName: String?, decoder: JSONDecoder,
                                 state: inout FoldState,
                                 records: inout [UsageRecord], malformed: inout Int) {
        // shrank ⇒ reset (compaction) ⇒ current value IS the new segment's delta and
        // becomes the new baseline; otherwise ordinary cumulative growth.
        func deltaFor(_ cur: Int, _ base: Int) -> Int { cur >= base ? cur - base : cur }

        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return }
        // Content gate — BEFORE the decoder. A non-whitelisted type is skipped as a raw
        // string, so its content is never decoded. Not counted as malformed: it's a
        // well-formed line we deliberately don't read.
        if let top = Self.topLevelType(of: trimmed), !Self.decodedTypes.contains(top) { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? decoder.decode(Line.self, from: data) else {
            malformed += 1   // tolerate half-written / trailing lines
            return
        }

        switch obj.type {
        case "session_meta":
            if let id = obj.payload?.id, !id.isEmpty { state.sessionId = id }
        case "turn_context":
            if let model = obj.payload?.model, !model.isEmpty { state.currentModel = model }
        case "event_msg" where obj.payload?.type == "token_count":
            let payload = obj.payload!
            // rate_limits snapshot (display only — never summed). Latest by ts.
            if let rl = payload.rate_limits {
                state.rateLimits = CodexRateLimitsSnapshot(
                    primary: window(rl.primary),
                    secondary: window(rl.secondary),
                    planType: rl.plan_type,
                    asOf: parseDate(obj.timestamp))
            }
            guard let T = payload.info?.total_token_usage else { return }  // info occasionally null

            let curInput = T.input_tokens ?? 0
            let curCached = T.cached_input_tokens ?? 0
            let curOutput = T.output_tokens ?? 0
            let dInput = deltaFor(curInput, state.prevInput)
            let dCached = deltaFor(curCached, state.prevCached)
            let dOutput = deltaFor(curOutput, state.prevOutput)
            state.prevInput = curInput; state.prevCached = curCached; state.prevOutput = curOutput

            // All-zero deltas ⇒ duplicate pair ⇒ emit nothing.
            if dInput == 0 && dCached == 0 && dOutput == 0 { return }

            // Canonical class mapping. OpenAI: cached ⊂ input, reasoning ⊂ output —
            // plain input is input minus cached; output is used as-is (reasoning already
            // inside it). cacheCreate has no Codex analog.
            let usage = TokenUsage(
                input: max(0, dInput - dCached),
                cacheCreate: 0,
                cacheRead: dCached,
                output: dOutput)

            records.append(UsageRecord(
                messageId: "codex:" + (state.sessionId ?? uuidFromFileName(fileName) ?? "<unknown>"),
                requestId: "token:\(state.seq)",
                model: state.currentModel ?? "<codex-unknown>",
                usage: usage,
                timestamp: parseDate(obj.timestamp),
                isSidechain: false,
                provider: "codex"))
            state.seq += 1
        default:
            // response_item, task_started, … — ignored WITHOUT decoding content.
            break
        }
    }

    private static func window(_ w: Line.RateLimits.Window?) -> CodexRateLimitsSnapshot.Window? {
        guard let w, let pct = w.used_percent else { return nil }
        // resets_at is epoch seconds in real logs; nil when absent.
        let reset = w.resets_at.map { Date(timeIntervalSince1970: $0) }
        return CodexRateLimitsSnapshot.Window(usedPercent: pct, resetsAt: reset, windowMinutes: w.window_minutes)
    }

    /// Parse one JSONL file (the per-file unit shared by the one-shot read and the cached
    /// refresh). A vanished/unreadable file is empty (tolerated mid-walk); a partial trailing
    /// line just counts as malformed.
    /// Lossy per-line UTF-8 decode + ASCII-only byte-level line breaking, for the reasons
    /// spelled out on LogReader.parseFile and in JSONLText: a strict decode threw away a whole
    /// file over one bad byte, and Foundation's `enumerateLines` cuts a single record into
    /// fragments at U+2028/U+2029/U+0085, none of which parse. Both readers must cut lines
    /// where Node does. `.mappedIfSafe` keeps the file's bytes clean/file-backed (append-only
    /// logs are never truncated in place, so the mapping cannot go bad).
    static func parseFile(_ url: URL) -> FileResult {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return FileResult(records: [], malformed: 0, rateLimits: nil)
        }
        var state = FoldState()
        let fileName = url.lastPathComponent
        let cut = parseComplete(data, from: 0, fileName: fileName, state: &state)
        var records = cut.records
        var malformed = cut.malformed
        if let p = cut.partial {   // a final line with no trailing newline still counts
            let tail = fold([p], fileName: fileName, state: &state)
            records += tail.records
            malformed += tail.malformed
        }
        return FileResult(records: records, malformed: malformed, rateLimits: state.rateLimits)
    }

    /// Incremental twin of `parseFile` for RecordCache: folds only the COMPLETE lines of
    /// `data` from `offset`, continuing from (and advancing) `state`. `consumed` is where the
    /// next tail parse resumes; `partial` is a trailing unterminated line, handed back
    /// UNCONSUMED — the caller counts it transiently against a COPY of `state` so the cached
    /// carry never includes a half line (see LogReader.parseComplete for the failure mode).
    static func parseComplete(_ data: Data, from offset: Int, fileName: String?,
                              state: inout FoldState)
        -> (records: [UsageRecord], malformed: Int, consumed: Int, partial: String?) {
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        // Enumerated, not collected: each raw line is folded and released during the scan —
        // the pre-gate raw lines include `response_item` content, which must never sit in
        // memory as a block (same bound as LogReader.parseComplete).
        let cut = JSONLText.enumerateCompleteLines(in: data, from: offset) { line in
            foldLine(line, fileName: fileName, decoder: decoder,
                     state: &state, records: &records, malformed: &malformed)
        }
        return (records, malformed, cut.consumed, cut.partial)
    }

    /// Read all Codex usage under `root`. `codexRateLimits` is the globally latest snapshot
    /// (by asOf) across all files — a snapshot without an asOf never displaces one that has a
    /// real timestamp (mirrors readCodexUsage). One-shot path (no caching); the app's refresh
    /// uses RecordCache so unchanged Codex files don't re-parse.
    static func readUsage(root: URL) -> (records: [UsageRecord], malformed: Int, codexRateLimits: CodexRateLimitsSnapshot?) {
        var records: [UsageRecord] = []
        var malformed = 0
        var latest: CodexRateLimitsSnapshot? = nil
        for url in findCodexJSONL(in: root) {
            let r = parseFile(url)
            records.append(contentsOf: r.records)
            malformed += r.malformed
            if let rl = r.rateLimits { latest = pickLatest(latest, rl) }
        }
        return (records, malformed, latest)
    }

    /// latest-wins by asOf: a snapshot with a later (or equal) asOf displaces the incumbent;
    /// one without an asOf never displaces one that has a real timestamp.
    static func pickLatest(_ current: CodexRateLimitsSnapshot?, _ next: CodexRateLimitsSnapshot) -> CodexRateLimitsSnapshot {
        guard let current else { return next }
        guard let b = next.asOf else { return current }
        guard let a = current.asOf else { return next }
        return b >= a ? next : current
    }
}
