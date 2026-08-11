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
    /// unreadable file is simply empty (tolerated mid-walk).
    /// Decoding is LOSSY on purpose (`String(decoding:as:)` substitutes U+FFFD rather than
    /// returning nil): a strict decode of a file with one bad byte returned ([], 0), throwing
    /// away every good record in it AND counting nothing malformed — a whole file of history
    /// gone with no signal. A half-written multi-byte character at the tail of a live log is
    /// enough to trigger it. Now only the damaged line fails to decode, and it is counted.
    /// Node substitutes U+FFFD the same way, so the two engines agree on the surviving lines.
    static func parseFile(_ url: URL) -> (records: [UsageRecord], malformed: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let text = String(decoding: data, as: UTF8.self)
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        // JSONLText.lines, not enumerateLines — see JSONLText for why Foundation's line
        // breaking silently drops records the JS engine counts.
        for rawLine in JSONLText.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8) else { malformed += 1; continue }
            guard let obj = try? decoder.decode(Line.self, from: lineData) else {
                malformed += 1; continue // tolerate a half-written live line
            }
            guard obj.type == "assistant", let m = obj.message, let u = m.usage else { continue }
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
        return (records, malformed)
    }
}

/// Per-file record cache: a refresh re-parses only the files whose mtime+size changed,
/// reusing cached records for the rest. This is what keeps active/idle CPU near zero —
/// without it, every FSEvents fire (many per turn while Claude Code writes logs) re-read
/// and re-parsed the entire history (~thousands of files), pegging a core. Records are
/// returned in `files` order, so the aggregator's first-seen dedup stays byte-identical
/// to the uncached path.
///
/// PERSISTENT across launches: the cache is hydrated from (and flushed to) a small file in
/// the app's own Caches container, keyed by absolute path + mtime + size. Logs are append-
/// only, so on a COLD launch only the files that changed since last run are re-parsed —
/// turning a multi-second full re-parse of the whole history (the loading-screen wall) into
/// a near-instant incremental one. Fail-soft throughout: a missing/corrupt/old-version store
/// just falls back to parsing, never throws. The cached records are metadata only (see
/// `UsageRecord`) — no prompt/code is ever written to disk.
///
/// `@unchecked Sendable`: the only mutation site is `UsageStore.refresh()`, serialized by
/// its `isRefreshing` guard, so `records(for:)` calls never overlap.
final class RecordCache: @unchecked Sendable {
    /// A per-file cache entry. `provider` distinguishes Claude vs Codex files so a mixed walk
    /// stays correct; `rateLimits` is a Codex file's latest rate_limits snapshot (nil for Claude,
    /// or for a Codex file with no snapshot) so an unchanged Codex file's snapshot survives without
    /// re-parsing. Both are v2 additions — old (v1) entries lacked them, hence the version bump.
    private struct Entry {
        let mtime: Date; let size: Int; let records: [UsageRecord]; let malformed: Int
        var provider: String = "claude"
        var rateLimits: CodexRateLimitsSnapshot? = nil
    }
    private var cache: [String: Entry] = [:]   // keyed by absolute file path

    /// Bump when the parse output shape changes, so an old build's cache is ignored, not trusted.
    /// v2: entries gained `provider` + a per-file Codex rate_limits snapshot.
    private static let version = 2
    private let storeURL: URL?
    private var hydrated = false
    private var dirty = false
    private var lastPersist = Date.distantPast
    private let persistInterval: TimeInterval = 30

    /// On-disk shape. Path strings (not URLs) so key equality is exact across launches. `provider`
    /// and `rateLimits` default so a truncated/old row still decodes — but the version gate below
    /// discards a v1 store outright (full re-parse), which is the real invalidation path.
    private struct PersistedEntry: Codable {
        var path: String; var mtime: Date; var size: Int; var records: [UsageRecord]; var malformed: Int
        var provider: String = "claude"
        var rateLimits: PersistedRateLimits? = nil
    }
    private struct PersistedCache: Codable { var version: Int; var entries: [PersistedEntry] }

    /// Codable mirror of the Core CodexRateLimitsSnapshot (which is Sendable but not Codable, and
    /// lives in a target we don't own), so a Codex file's official snapshot round-trips through the
    /// on-disk cache. Kept in sync structurally with CodexRateLimitsSnapshot.
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
        return dir.appendingPathComponent("record-cache-v\(version).json")
    }

    func records(for files: [URL]) -> (records: [UsageRecord], malformed: Int) {
        hydrateIfNeeded()
        var records: [UsageRecord] = []
        var malformed = 0
        var seen = Set<String>(minimumCapacity: files.count)
        for url in files {
            let path = url.path
            seen.insert(path)
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? -1
            // Hit: file unchanged since we parsed it (logs are append-only, so mtime+size
            // is a sound fingerprint). Reuse without touching disk. The provider guard
            // mirrors the Codex branch — the roots are disjoint, but symmetry keeps a
            // path collision from ever crossing providers.
            if let e = cache[path], e.mtime == mtime, e.size == size, e.provider == "claude" {
                records.append(contentsOf: e.records)
                malformed += e.malformed
                continue
            }
            let (r, m) = LogReader.parseFile(url)
            cache[path] = Entry(mtime: mtime, size: size, records: r, malformed: m)
            dirty = true
            records.append(contentsOf: r)
            malformed += m
        }
        // Drop vanished CLAUDE files so the cache stays bounded — but leave Codex entries alone
        // (they aren't in this walk's `seen` set; codexRecords prunes its own vanished files).
        pruneVanished(seen: seen, provider: "claude")
        persistIfNeeded()
        return (records, malformed)
    }

    /// Remove cache entries for a given provider whose paths didn't appear in the latest walk.
    /// Scoped by provider so the Claude and Codex refresh passes (which share this store) don't
    /// evict each other's still-live files.
    private func pruneVanished(seen: Set<String>, provider: String) {
        let before = cache.count
        cache = cache.filter { $0.value.provider != provider || seen.contains($0.key) }
        if cache.count != before { dirty = true }
    }

    /// The Codex counterpart of `records(for:)`: re-parses only changed Codex files (mtime+size),
    /// reusing cached records AND each file's rate_limits snapshot for the rest — so an unchanged
    /// Codex file never re-reads even to refresh its official %. Records come back in `files` order
    /// (deterministic fold), and `codexRateLimits` is the globally latest snapshot by asOf. Shares
    /// the same on-disk store as the Claude path; the per-entry `provider` keeps the two apart.
    func codexRecords(for files: [URL]) -> (records: [UsageRecord], malformed: Int, codexRateLimits: CodexRateLimitsSnapshot?) {
        hydrateIfNeeded()
        var records: [UsageRecord] = []
        var malformed = 0
        var latest: CodexRateLimitsSnapshot? = nil
        var seen = Set<String>(minimumCapacity: files.count)
        for url in files {
            let path = url.path
            seen.insert(path)
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? -1
            if let e = cache[path], e.mtime == mtime, e.size == size, e.provider == "codex" {
                records.append(contentsOf: e.records)
                malformed += e.malformed
                if let rl = e.rateLimits { latest = CodexLogReader.pickLatest(latest, rl) }
                continue
            }
            let r = CodexLogReader.parseFile(url)
            cache[path] = Entry(mtime: mtime, size: size, records: r.records, malformed: r.malformed,
                                provider: "codex", rateLimits: r.rateLimits)
            dirty = true
            records.append(contentsOf: r.records)
            malformed += r.malformed
            if let rl = r.rateLimits { latest = CodexLogReader.pickLatest(latest, rl) }
        }
        pruneVanished(seen: seen, provider: "codex")
        persistIfNeeded()
        return (records, malformed, latest)
    }

    /// Load the persisted cache once, before the first parse. A missing/corrupt/old-version
    /// file leaves the cache empty (full cold parse) — exactly the behavior before persistence.
    private func hydrateIfNeeded() {
        guard !hydrated else { return }
        hydrated = true
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedCache.self, from: data),
              decoded.version == Self.version else { return }
        for e in decoded.entries {
            cache[e.path] = Entry(mtime: e.mtime, size: e.size, records: e.records, malformed: e.malformed,
                                  provider: e.provider, rateLimits: e.rateLimits?.snapshot())
        }
    }

    /// Flush the cache when it changed, throttled so an active session's once-a-second
    /// refreshes don't rewrite the whole file each time. A few-seconds-stale store is fine:
    /// at worst the next launch re-parses the handful of files touched since the last flush.
    private func persistIfNeeded() {
        guard dirty, let url = storeURL, Date().timeIntervalSince(lastPersist) >= persistInterval else { return }
        lastPersist = Date()
        dirty = false
        let entries = cache.map { PersistedEntry(path: $0.key, mtime: $0.value.mtime,
                                                 size: $0.value.size, records: $0.value.records,
                                                 malformed: $0.value.malformed, provider: $0.value.provider,
                                                 rateLimits: $0.value.rateLimits.map(PersistedRateLimits.init)) }
        guard let data = try? JSONEncoder().encode(PersistedCache(version: Self.version, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
