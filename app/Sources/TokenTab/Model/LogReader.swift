// Token Tab — the I/O shell (Swift port of the file-walking half of token-tab.mjs).
//
// Walks the Claude Code log dir, streams each JSONL file line-by-line, decodes ONLY the
// metadata fields the core needs, and hands UsageRecords to the pure aggregator. It
// never decodes `message.content` (your prompts/code): the Codable struct below simply
// has no field for it, so there is no code path that reads it. No network, ever.

import Foundation
import TokenTabCore

enum LogReader {
    /// Log-dir resolution mirrors token-tab.mjs:
    ///   $TOKENTAB_LOG_DIR  >  $CLAUDE_CONFIG_DIR/projects  >  ~/.claude/projects
    ///
    /// Read via `Config.string`, not the raw environment, so the env/dotfile precedence
    /// matches the JS engine — which resolves these through loadLocalConfig(). A sandboxed
    /// GUI app inherits no shell env, so reading `ProcessInfo` alone meant a relocated
    /// TOKENTAB_LOG_DIR set in ~/.config/token-tab/env moved the CLI and not the app: same
    /// Mac, same setting, one reads the logs and the other reports zero. CodexLogReader
    /// .defaultCodexRoot() has always gone through Config; this is the Claude-side twin.
    static func defaultLogDir() -> URL {
        if let d = Config.string("TOKENTAB_LOG_DIR"), !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        }
        if let c = Config.string("CLAUDE_CONFIG_DIR"), !c.isEmpty {
            return URL(fileURLWithPath: (c as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// All *.jsonl under `dir`, oldest mtime first so first-seen dedup is reproducible
    /// (matches findJsonl in the JS shell — which recurses into ALL directories, including
    /// hidden ones, so we must NOT skip hidden paths or the two engines' input sets diverge).
    /// The `.jsonl` filter still excludes the hidden live-cache file (.token-tab-live.json,
    /// extension `json`). Tolerates files vanishing mid-walk.
    static func findJSONL(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: []) else { return [] }
        var out: [(url: URL, mtime: Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            out.append((url, vals?.contentModificationDate ?? .distantPast))
        }
        return out.sorted {
            $0.mtime != $1.mtime ? $0.mtime < $1.mtime : $0.url.path < $1.url.path
        }.map(\.url)
    }

    /// Only the metadata fields we count. No `content` key exists here on purpose — the
    /// decoder physically cannot surface your prompts or code.
    private struct Line: Decodable {
        let type: String?
        let requestId: String?
        let timestamp: String?
        let isSidechain: Bool?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
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

    /// Read every file and return the usage records (assistant turns carrying usage).
    /// `malformed` counts skipped bad lines (count only — never the bad line's content).
    /// One-shot path (Probe): no caching. The app's refresh uses `RecordCache` so it only
    /// re-parses files that actually changed.
    static func readRecords(from files: [URL]) -> (records: [UsageRecord], malformed: Int) {
        var records: [UsageRecord] = []
        var malformed = 0
        for url in files {
            let (r, m) = parseFile(url)
            records.append(contentsOf: r)
            malformed += m
        }
        return (records, malformed)
    }

    /// Parse one JSONL file into usage records (+ a count of malformed lines). The per-file
    /// unit shared by the one-shot `readRecords` and the cached refresh path. A vanished or
    /// unreadable file is simply empty (tolerated mid-walk). `.mappedIfSafe` keeps the file's
    /// bytes as clean, file-backed pages — the parse's dirty memory is one line at a time
    /// (see JSONLText.completeLines), not 2× the file. Safe because the logs are append-only:
    /// mapped pages could only go bad if a file were truncated in place, which never happens.
    static func parseFile(_ url: URL) -> (records: [UsageRecord], malformed: Int) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return ([], 0) }
        let cut = parseComplete(data, from: 0)
        var records = cut.records
        var malformed = cut.malformed
        if let p = cut.partial {   // a final line with no trailing newline still counts
            let decoder = JSONDecoder()
            parseLine(p, decoder: decoder, into: &records, malformed: &malformed)
        }
        return (records, malformed)
    }

    /// Parse only the COMPLETE (newline-terminated) lines of `data` from `offset` — the
    /// incremental unit RecordCache resumes from. `consumed` is where the next tail parse
    /// starts; `partial` is a trailing line still being appended, handed back UNCONSUMED so
    /// the caller can count it transiently now and re-parse it whole once it terminates.
    /// Caching a half line would poison the resume offset: its remainder would arrive as a
    /// fresh "line" that parses as garbage while the half stays counted forever.
    static func parseComplete(_ data: Data, from offset: Int)
        -> (records: [UsageRecord], malformed: Int, consumed: Int, partial: String?) {
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        // Enumerated, not collected: each raw line is parsed and released during the scan, so
        // dirty memory is one line + the records — never the file's decoded text as a block.
        let cut = JSONLText.enumerateCompleteLines(in: data, from: offset) { line in
            parseLine(line, decoder: decoder, into: &records, malformed: &malformed)
        }
        return (records, malformed, cut.consumed, cut.partial)
    }

    /// Decode a single already-cut line. Decoding is LOSSY upstream on purpose (U+FFFD for
    /// damaged bytes, matching Node): a strict whole-file decode used to return ([], 0) for
    /// one bad byte, throwing away every good record in the file AND counting nothing
    /// malformed. Here only the damaged line fails to decode, and it is counted.
    static func parseLine(_ rawLine: String, decoder: JSONDecoder,
                          into records: inout [UsageRecord], malformed: inout Int) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        guard let lineData = line.data(using: .utf8) else { malformed += 1; return }
        guard let obj = try? decoder.decode(Line.self, from: lineData) else {
            malformed += 1; return // tolerate a half-written live line
        }
        guard obj.type == "assistant", let m = obj.message, let u = m.usage else { return }
        let usage = TokenUsage(
            input: u.input_tokens ?? 0,
            cacheCreate: u.cache_creation_input_tokens ?? 0,
            cacheRead: u.cache_read_input_tokens ?? 0,
            output: u.output_tokens ?? 0
        )
        records.append(UsageRecord(
            messageId: m.id,
            requestId: obj.requestId,
            model: m.model ?? "<unknown>",
            usage: usage,
            timestamp: parseDate(obj.timestamp),
            isSidechain: obj.isSidechain ?? false
        ))
    }
}

/// Per-file record cache: a refresh re-parses only the files whose mtime+size changed —
/// and, because logs are APPEND-ONLY, a grown file re-parses only its appended tail, not
/// the whole file. This is what keeps active/idle CPU and memory churn near zero: without
/// the cache, every FSEvents fire (many per turn while Claude Code writes logs) re-read
/// and re-parsed the entire history (~thousands of files), pegging a core; without tail
/// parsing, every fire re-read the ACTIVE session file (tens of MB late in a session) in
/// full. Records are returned in `files` order, so the aggregator's first-seen dedup stays
/// byte-identical to the uncached path.
///
/// Entries track `parsedBytes` — the offset past the last COMPLETE (newline-terminated)
/// line consumed. A trailing half-written line is never cached: it is parsed transiently
/// each refresh and re-parsed whole once its terminator arrives, so an in-flight line can
/// never poison the resume offset (see LogReader.parseComplete). Codex entries also carry
/// the fold's `FoldState`, because Codex counters are cumulative — a tail can't be folded
/// without the baselines the earlier lines established.
///
/// PERSISTENT across launches: the cache is hydrated from (and flushed to) a JSONL file in
/// the app's own Caches container — a `{"version":N}` header line, then one entry per line,
/// encoded and decoded ONE LINE AT A TIME. (The v2 store was a single JSON blob; encoding
/// it made Foundation build a boxed tree of every record in history — a >100 MB allocation
/// spike every flush that dominated the app's real memory footprint.) Logs are append-only,
/// so on a COLD launch only the bytes appended since last run are parsed. Fail-soft
/// throughout: a missing/corrupt/old-version store just falls back to parsing, never
/// throws; a single damaged line costs that entry only. The cached records are metadata
/// only (see `UsageRecord`) — no prompt/code is ever written to disk.
///
/// `@unchecked Sendable`: the only mutation site is `UsageStore.refresh()`, serialized by
/// its `isRefreshing` guard, so `records(for:)` calls never overlap.
final class RecordCache: @unchecked Sendable {
    /// A per-file cache entry. `provider` distinguishes Claude vs Codex files so a mixed walk
    /// stays correct. `parsedBytes` is the tail-parse resume offset (≤ size; == size for a
    /// file ending in a newline, which they essentially always do). `codexState` is the fold
    /// carry for Codex files (nil for Claude); its `rateLimits` is the file's latest official
    /// snapshot, surviving without a re-parse.
    private struct Entry {
        let mtime: Date; let size: Int; let records: [UsageRecord]; let malformed: Int
        var provider: String = "claude"
        var parsedBytes: Int
        var codexState: CodexLogReader.FoldState? = nil
    }
    private var cache: [String: Entry] = [:]   // keyed by absolute file path

    /// Bump when the parse output shape changes, so an old build's cache is ignored, not trusted.
    /// v3: JSONL store (header + one entry per line), `parsedBytes`, Codex fold state.
    /// v4: records carry a `dedupKey` fingerprint instead of `messageId`/`requestId`. A v3
    ///     store decoded as v4 would give every record a nil key — nothing would ever collapse
    ///     and totals would roughly double — so the version gate discarding it is load-bearing,
    ///     not housekeeping. Costs one cold re-parse on the upgrade launch.
    private static let version = 4
    /// Superseded store files, deleted after a successful flush (~50 MB of dead cache
    /// otherwise sits in Caches forever). Names only — never anything we didn't write.
    private static let supersededStores = [
        "record-cache-v1.json", "record-cache-v2.json", "record-cache-v3.jsonl",
    ]
    private let storeURL: URL?
    private var hydrated = false
    private var dirty = false
    private var lastPersist = Date.distantPast
    private let persistInterval: TimeInterval = 30

    /// On-disk shape, one per line. Path strings (not URLs) so key equality is exact across
    /// launches. The header line's version gate discards an old store outright (full re-parse);
    /// within a current-version store, a damaged line skips that entry only.
    private struct PersistedEntry: Codable {
        var path: String; var mtime: Date; var size: Int; var records: [UsageRecord]; var malformed: Int
        var provider: String
        var parsedBytes: Int
        var codexState: PersistedFoldState? = nil
    }
    private struct Header: Codable { var version: Int }

    /// Codable mirror of CodexLogReader.FoldState (whose `rateLimits` is the Core
    /// CodexRateLimitsSnapshot — Sendable but not Codable, in a target we don't own).
    /// Kept structurally in sync with FoldState.
    private struct PersistedFoldState: Codable {
        var prevInput: Int; var prevCached: Int; var prevOutput: Int
        var sessionId: String?; var currentModel: String?; var seq: Int
        var rateLimits: PersistedRateLimits?

        init(_ s: CodexLogReader.FoldState) {
            prevInput = s.prevInput; prevCached = s.prevCached; prevOutput = s.prevOutput
            sessionId = s.sessionId; currentModel = s.currentModel; seq = s.seq
            rateLimits = s.rateLimits.map(PersistedRateLimits.init)
        }
        func state() -> CodexLogReader.FoldState {
            var s = CodexLogReader.FoldState()
            s.prevInput = prevInput; s.prevCached = prevCached; s.prevOutput = prevOutput
            s.sessionId = sessionId; s.currentModel = currentModel; s.seq = seq
            s.rateLimits = rateLimits?.snapshot()
            return s
        }
    }

    /// Codable mirror of the Core CodexRateLimitsSnapshot, so a Codex file's official snapshot
    /// round-trips through the on-disk cache. Kept in sync structurally with CodexRateLimitsSnapshot.
    private struct PersistedRateLimits: Codable {
        struct Window: Codable { var usedPercent: Double; var resetsAt: Date?; var windowMinutes: Int? }
        var primary: Window?
        var secondary: Window?
        var planType: String?
        var asOf: Date?

        init(_ s: CodexRateLimitsSnapshot) {
            func w(_ x: CodexRateLimitsSnapshot.Window?) -> Window? {
                x.map { Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes) }
            }
            primary = w(s.primary); secondary = w(s.secondary); planType = s.planType; asOf = s.asOf
        }
        func snapshot() -> CodexRateLimitsSnapshot {
            func w(_ x: Window?) -> CodexRateLimitsSnapshot.Window? {
                x.map { CodexRateLimitsSnapshot.Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes) }
            }
            return CodexRateLimitsSnapshot(primary: w(primary), secondary: w(secondary), planType: planType, asOf: asOf)
        }
    }

    /// `storeURL == nil` disables persistence (the default — used by tests so they stay
    /// hermetic). The app passes `defaultStoreURL()` to get cross-launch reuse.
    init(storeURL: URL? = nil) { self.storeURL = storeURL }

    /// The cache file inside the app container's Caches dir — writable in the sandbox with no
    /// entitlement, and outside `~/.claude` so it never pollutes the log walk. nil if it can't
    /// be located/created, in which case the cache stays in-memory (cold parse each launch).
    static func defaultStoreURL() -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true) else { return nil }
        let dir = caches.appendingPathComponent("TokenTab", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("record-cache-v\(version).jsonl")
    }

    /// How many records the cache is currently holding, for one provider or all of them.
    /// Lets a refresh size its flat record array ONCE up front: built from empty, a ~115k-record
    /// history grows through ~17 reallocations (~26 MB of copying), and every abandoned buffer
    /// is a dirty page malloc then holds on its free list rather than returning to the OS.
    func cachedRecordCount(provider: String? = nil) -> Int {
        hydrateIfNeeded()
        var n = 0
        for e in cache.values where provider == nil || e.provider == provider {
            n += e.records.count
        }
        return n
    }

    func records(for files: [URL]) -> (records: [UsageRecord], malformed: Int) {
        var records: [UsageRecord] = []
        records.reserveCapacity(cachedRecordCount(provider: "claude"))
        let malformed = appendRecords(for: files, into: &records)
        return (records, malformed)
    }

    /// Appending twin of `records(for:)`, so the Claude and Codex passes can fill ONE array
    /// sized for both. Returning a fresh Claude array and then appending Codex to it triggers
    /// a copy-on-write duplication of the whole history every refresh.
    @discardableResult
    func appendRecords(for files: [URL], into records: inout [UsageRecord]) -> Int {
        hydrateIfNeeded()
        var malformed = 0
        var seen = Set<String>(minimumCapacity: files.count)
        for url in files {
            let path = url.path
            seen.insert(path)
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? -1
            // Hit: file unchanged since we parsed it (logs are append-only, so mtime+size
            // is a sound fingerprint). Reuse without touching disk — except the rare file
            // whose last line had no newline yet: its unconsumed tail is counted
            // transiently, never cached. The provider guard mirrors the Codex branch —
            // the roots are disjoint, but symmetry keeps a path collision from ever
            // crossing providers.
            if let e = cache[path], e.mtime == mtime, e.size == size, e.provider == "claude" {
                records.append(contentsOf: e.records)
                malformed += e.malformed
                if e.parsedBytes < e.size {
                    appendClaudeTail(of: url, from: e.parsedBytes, into: &records, malformed: &malformed)
                }
                continue
            }
            // Grown in place: parse ONLY the appended bytes, keeping the cached prefix.
            // Sound because logs are append-only — a same-path rewrite would keep the old
            // prefix records, but neither CLI ever rewrites a session file (compaction and
            // resume both create NEW files). Shrinkage or same-size mtime drift (below)
            // still falls through to a full re-parse.
            if let e = cache[path], e.provider == "claude", size > e.size,
               let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
               data.count >= e.parsedBytes {
                let cut = LogReader.parseComplete(data, from: e.parsedBytes)
                let entry = Entry(mtime: mtime, size: size,
                                  records: e.records + cut.records,
                                  malformed: e.malformed + cut.malformed,
                                  parsedBytes: cut.consumed)
                cache[path] = entry
                dirty = true
                records.append(contentsOf: entry.records)
                malformed += entry.malformed
                appendTransientPartial(cut.partial, into: &records, malformed: &malformed)
                continue
            }
            // Cold, shrunk, or rewritten: full parse. Complete lines are cached; a trailing
            // half line is counted transiently only (same rule as everywhere).
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                cache[path] = Entry(mtime: mtime, size: size, records: [], malformed: 0, parsedBytes: 0)
                dirty = true
                continue   // vanished/unreadable mid-walk: empty, tolerated
            }
            let cut = LogReader.parseComplete(data, from: 0)
            cache[path] = Entry(mtime: mtime, size: size, records: cut.records,
                                malformed: cut.malformed, parsedBytes: cut.consumed)
            dirty = true
            records.append(contentsOf: cut.records)
            malformed += cut.malformed
            appendTransientPartial(cut.partial, into: &records, malformed: &malformed)
        }
        // Drop vanished CLAUDE files so the cache stays bounded — but leave Codex entries alone
        // (they aren't in this walk's `seen` set; codexRecords prunes its own vanished files).
        pruneVanished(seen: seen, provider: "claude")
        persistIfNeeded()
        return malformed
    }

    /// Count a trailing not-yet-terminated line for THIS refresh only (never cached).
    private func appendTransientPartial(_ partial: String?,
                                        into records: inout [UsageRecord], malformed: inout Int) {
        guard let partial else { return }
        LogReader.parseLine(partial, decoder: JSONDecoder(), into: &records, malformed: &malformed)
    }

    /// Re-read the unconsumed tail of an otherwise-unchanged file (its last line had no
    /// newline when cached) and count whatever it holds transiently.
    private func appendClaudeTail(of url: URL, from offset: Int,
                                  into records: inout [UsageRecord], malformed: inout Int) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count > offset else { return }
        let cut = LogReader.parseComplete(data, from: offset)
        records.append(contentsOf: cut.records)
        malformed += cut.malformed
        appendTransientPartial(cut.partial, into: &records, malformed: &malformed)
    }

    /// Remove cache entries for a given provider whose paths didn't appear in the latest walk.
    /// Scoped by provider so the Claude and Codex refresh passes (which share this store) don't
    /// evict each other's still-live files.
    private func pruneVanished(seen: Set<String>, provider: String) {
        let before = cache.count
        cache = cache.filter { $0.value.provider != provider || seen.contains($0.key) }
        if cache.count != before { dirty = true }
    }

    /// The Codex counterpart of `records(for:)`: re-parses only changed Codex files — and only
    /// their appended tails, resuming from the entry's `FoldState` (Codex counters are
    /// cumulative; the baselines ARE the parse position). An unchanged Codex file never
    /// re-reads even to refresh its official %: its `codexState.rateLimits` survives in the
    /// entry. Records come back in `files` order (deterministic fold), and `codexRateLimits`
    /// is the globally latest snapshot by asOf. Shares the same on-disk store as the Claude
    /// path; the per-entry `provider` keeps the two apart.
    func codexRecords(for files: [URL]) -> (records: [UsageRecord], malformed: Int, codexRateLimits: CodexRateLimitsSnapshot?) {
        var records: [UsageRecord] = []
        records.reserveCapacity(cachedRecordCount(provider: "codex"))
        let r = appendCodexRecords(for: files, into: &records)
        return (records, r.malformed, r.codexRateLimits)
    }

    /// Appending twin of `codexRecords(for:)` — see `appendRecords(for:into:)`.
    func appendCodexRecords(for files: [URL], into records: inout [UsageRecord])
        -> (malformed: Int, codexRateLimits: CodexRateLimitsSnapshot?) {
        hydrateIfNeeded()
        var malformed = 0
        var latest: CodexRateLimitsSnapshot? = nil
        var seen = Set<String>(minimumCapacity: files.count)
        for url in files {
            let path = url.path
            seen.insert(path)
            let fileName = url.lastPathComponent
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? -1
            if let e = cache[path], e.mtime == mtime, e.size == size, e.provider == "codex" {
                records.append(contentsOf: e.records)
                malformed += e.malformed
                var tailState = e.codexState ?? CodexLogReader.FoldState()
                if e.parsedBytes < e.size,
                   let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                   data.count > e.parsedBytes {
                    // Unconsumed no-newline tail: fold transiently against a COPY of the
                    // cached state — the entry itself must never absorb a half line.
                    let cut = CodexLogReader.parseComplete(data, from: e.parsedBytes,
                                                           fileName: fileName, state: &tailState)
                    records.append(contentsOf: cut.records)
                    malformed += cut.malformed
                    if let p = cut.partial {
                        let t = CodexLogReader.fold([p], fileName: fileName, state: &tailState)
                        records.append(contentsOf: t.records)
                        malformed += t.malformed
                    }
                }
                if let rl = tailState.rateLimits { latest = CodexLogReader.pickLatest(latest, rl) }
                continue
            }
            // Grown in place: fold ONLY the appended bytes, resuming from the cached state
            // (same append-only reasoning as the Claude branch).
            if let e = cache[path], e.provider == "codex", size > e.size, var state = e.codexState,
               let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
               data.count >= e.parsedBytes {
                let cut = CodexLogReader.parseComplete(data, from: e.parsedBytes,
                                                       fileName: fileName, state: &state)
                let entry = Entry(mtime: mtime, size: size,
                                  records: e.records + cut.records,
                                  malformed: e.malformed + cut.malformed,
                                  provider: "codex", parsedBytes: cut.consumed, codexState: state)
                cache[path] = entry
                dirty = true
                records.append(contentsOf: entry.records)
                malformed += entry.malformed
                var tailState = state
                if let p = cut.partial {
                    let t = CodexLogReader.fold([p], fileName: fileName, state: &tailState)
                    records.append(contentsOf: t.records)
                    malformed += t.malformed
                }
                if let rl = tailState.rateLimits { latest = CodexLogReader.pickLatest(latest, rl) }
                continue
            }
            // Cold, shrunk, or rewritten: full fold from a fresh state.
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                cache[path] = Entry(mtime: mtime, size: size, records: [], malformed: 0,
                                    provider: "codex", parsedBytes: 0, codexState: CodexLogReader.FoldState())
                dirty = true
                continue   // vanished/unreadable mid-walk: empty, tolerated
            }
            var state = CodexLogReader.FoldState()
            let cut = CodexLogReader.parseComplete(data, from: 0, fileName: fileName, state: &state)
            cache[path] = Entry(mtime: mtime, size: size, records: cut.records,
                                malformed: cut.malformed,
                                provider: "codex", parsedBytes: cut.consumed, codexState: state)
            dirty = true
            records.append(contentsOf: cut.records)
            malformed += cut.malformed
            var tailState = state
            if let p = cut.partial {
                let t = CodexLogReader.fold([p], fileName: fileName, state: &tailState)
                records.append(contentsOf: t.records)
                malformed += t.malformed
            }
            if let rl = tailState.rateLimits { latest = CodexLogReader.pickLatest(latest, rl) }
        }
        pruneVanished(seen: seen, provider: "codex")
        persistIfNeeded()
        return (malformed, latest)
    }

    /// Load the persisted cache once, before the first parse. A missing/corrupt/old-version
    /// file leaves the cache empty (full cold parse) — exactly the behavior before persistence.
    /// The store stays a mapped (clean, file-backed) buffer scanned line by line; only ONE
    /// line's Data and decoded entry are alive at a time, so hydration's dirty-memory peak is
    /// an entry, not the store. A damaged entry line is skipped alone.
    private func hydrateIfNeeded() {
        guard !hydrated else { return }
        hydrated = true
        guard let url = storeURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var checkedHeader = false
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex   // we only ever write \n
            let line = data[start..<nl]
            start = nl == data.endIndex ? data.endIndex : data.index(after: nl)
            if line.isEmpty { continue }
            if !checkedHeader {
                checkedHeader = true
                guard let header = try? decoder.decode(Header.self, from: Data(line)),
                      header.version == Self.version else { return }   // old/corrupt store: cold parse
                continue
            }
            guard let e = try? decoder.decode(PersistedEntry.self, from: Data(line)) else { continue }
            // A decoded entry is still INPUT DATA (the store is user-editable by design — we
            // tell people to open it). An offset outside [0, size] can't be a real parse
            // position; installing it would feed garbage to the resume paths, so the entry is
            // dropped and its file simply re-parses.
            guard e.parsedBytes >= 0, e.parsedBytes <= e.size else { continue }
            cache[e.path] = Entry(mtime: e.mtime, size: e.size, records: e.records, malformed: e.malformed,
                                  provider: e.provider, parsedBytes: e.parsedBytes,
                                  codexState: e.codexState?.state())
        }
    }

    /// Flush the cache when it changed, throttled so an active session's once-a-second
    /// refreshes don't rewrite the whole file each time. A few-seconds-stale store is fine:
    /// at worst the next launch re-parses the handful of files touched since the last flush.
    /// One encode per entry, STREAMED to a temp file and swapped in whole: peak transient
    /// memory is a single entry's tree — never a boxed tree (or even a buffer) of the entire
    /// history, which is what made the old single-blob flush the app's biggest allocation.
    private func persistIfNeeded() {
        guard dirty, let url = storeURL, Date().timeIntervalSince(lastPersist) >= persistInterval else { return }
        lastPersist = Date()
        dirty = false
        let fm = FileManager.default
        let encoder = JSONEncoder()
        guard let headerLine = try? encoder.encode(Header(version: Self.version)) else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmp) else { return }
        let newline = Data([0x0A])
        var ok = true
        func writeLine(_ line: Data) {
            guard ok else { return }
            do { try handle.write(contentsOf: line); try handle.write(contentsOf: newline) }
            catch { ok = false }
        }
        writeLine(headerLine)
        for (path, e) in cache {
            let pe = PersistedEntry(path: path, mtime: e.mtime, size: e.size, records: e.records,
                                    malformed: e.malformed, provider: e.provider,
                                    parsedBytes: e.parsedBytes,
                                    codexState: e.codexState.map(PersistedFoldState.init))
            guard let line = try? encoder.encode(pe) else { continue }
            writeLine(line)
        }
        try? handle.close()
        guard ok else { try? fm.removeItem(at: tmp); return }
        // Whole-file swap, so a reader never sees a half-written store (hydration tolerates
        // one anyway, but there's no reason to ever produce one).
        if fm.fileExists(atPath: url.path) {
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try? fm.moveItem(at: tmp, to: url)
        }
        // The new store is on disk — the superseded blob formats are dead weight now.
        let dir = url.deletingLastPathComponent()
        for name in Self.supersededStores {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
