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
    static func defaultLogDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let d = env["TOKENTAB_LOG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        }
        if let c = env["CLAUDE_CONFIG_DIR"], !c.isEmpty {
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
    static func parseFile(_ url: URL) -> (records: [UsageRecord], malformed: Int) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return ([], 0) }
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        text.enumerateLines { rawLine, _ in
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
/// `@unchecked Sendable`: the only mutation site is `UsageStore.refresh()`, serialized by
/// its `isRefreshing` guard, so `records(for:)` calls never overlap.
final class RecordCache: @unchecked Sendable {
    private struct Entry { let mtime: Date; let size: Int; let records: [UsageRecord]; let malformed: Int }
    private var cache: [URL: Entry] = [:]

    func records(for files: [URL]) -> (records: [UsageRecord], malformed: Int) {
        var records: [UsageRecord] = []
        var malformed = 0
        var seen = Set<URL>(minimumCapacity: files.count)
        for url in files {
            seen.insert(url)
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? -1
            // Hit: file unchanged since we parsed it (logs are append-only, so mtime+size
            // is a sound fingerprint). Reuse without touching disk.
            if let e = cache[url], e.mtime == mtime, e.size == size {
                records.append(contentsOf: e.records)
                malformed += e.malformed
                continue
            }
            let (r, m) = LogReader.parseFile(url)
            cache[url] = Entry(mtime: mtime, size: size, records: r, malformed: m)
            records.append(contentsOf: r)
            malformed += m
        }
        if cache.count > seen.count {           // drop vanished files so the cache stays bounded
            cache = cache.filter { seen.contains($0.key) }
        }
        return (records, malformed)
    }
}
