// Token Tab — reader for the opt-in live-usage cache.
//
// The sandboxed app CANNOT run `claude /usage` (no network, no subprocess — by design).
// Instead the opt-in sidecar (adapters/write-live.mjs, a separate user-launched process)
// does that call and writes the parsed percentages to a small JSON file. This reader just
// loads that file as data — same trust posture as reading the logs. No network, ever.
//
// Location: `<logDir>/.token-tab-live.json`. logDir is always ~/.claude/projects, and the
// security scope the user granted (~/.claude OR its projects subfolder) always contains it,
// so the file is readable under either grant — and directly in the unsandboxed dev build.
// Both log walkers skip it (hidden + not *.jsonl), so it never pollutes the token counts.
//
// Fail closed: any problem (missing file, bad JSON, wrong shape) returns nil and the app
// falls back to the calibrated cap or the time countdown. A half-written file never throws.

import Foundation
import TokenTabCore

enum LiveReader {
    static let fileName = ".token-tab-live.json"

    static func cacheURL(logDir: URL) -> URL {
        logDir.appendingPathComponent(fileName)
    }

    /// The on-disk shape the sidecar writes (see adapters/write-live.mjs). Decoupled from
    /// the core's `LiveUsage` so a schema bump here can't ripple into the pure model.
    private struct DTO: Decodable {
        var schema: Int?
        var sessionPct: Int?
        var sessionResetText: String?
        var weeklyPct: Int?
        var weeklyResetText: String?
        var weeklyByModel: [String: Int]?
        var capturedAt: String?
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

    /// Load the live reading, or nil if absent/unreadable/malformed. Never throws.
    static func read(logDir: URL) -> LiveUsage? {
        let url = cacheURL(logDir: logDir)
        guard let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        // A reading with no percentages at all is useless — treat as absent.
        if dto.sessionPct == nil && dto.weeklyPct == nil { return nil }
        let captured = dto.capturedAt.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
        return LiveUsage(sessionPct: dto.sessionPct,
                         sessionResetText: dto.sessionResetText,
                         weeklyPct: dto.weeklyPct,
                         weeklyResetText: dto.weeklyResetText,
                         weeklyByModel: dto.weeklyByModel ?? [:],
                         capturedAt: captured)
    }
}
