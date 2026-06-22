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
    /// (matches findJsonl in the JS shell). Tolerates files vanishing mid-walk.
    static func findJSONL(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
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
    static func readRecords(from files: [URL]) -> (records: [UsageRecord], malformed: Int) {
        var records: [UsageRecord] = []
        var malformed = 0
        let decoder = JSONDecoder()
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
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
        }
        return (records, malformed)
    }
}
