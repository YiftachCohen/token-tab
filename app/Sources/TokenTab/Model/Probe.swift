// Token Tab — a headless `--probe` mode.
//
// Runs the exact same read + aggregate the menu bar uses and prints the totals as JSON,
// then exits before any UI starts. Two uses: (1) reconcile the native engine against the
// audited JS engine (`node ../src/token-tab.mjs --json`) on real logs, and (2) let a
// skeptic see precisely which numbers the app derives. Reads the default log dir
// directly (no sandbox), so run the bare binary, not the sandboxed .app.

import Foundation
import TokenTabCore

enum Probe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--probe") else { return }
        let dir = LogReader.defaultLogDir()
        let files = LogReader.findJSONL(in: dir)
        let (records, malformed) = LogReader.readRecords(from: files)
        let agg = aggregate(records, options: AggregateOptions(cap: Config.windowCap), costModel: Pricing())
        let live = LiveReader.read(logDir: dir)   // opt-in live cache, if the sidecar wrote one

        var surfaces: [String: Int] = [:]
        for (s, n) in agg.bySurface { surfaces[s.rawValue] = n }

        var out: [String: Any] = [
            "files": files.count,
            "malformed": malformed,
            "counted": agg.counted,
            "duplicatesDropped": agg.duplicatesDropped,
            "total": agg.total,
            "today": agg.today,
            "thisWeek": agg.thisWeek,
            "rolling5h": agg.rolling5h,
            "lastHourTokens": agg.lastHourTokens,
            "byClass": [
                "input": agg.byClass.input, "cacheCreate": agg.byClass.cacheCreate,
                "cacheRead": agg.byClass.cacheRead, "output": agg.byClass.output,
            ],
            "bySurface": surfaces,
            "split": ["main": agg.split.mainTokens, "sub": agg.split.subTokens],
            "window": [
                "active": agg.window.active,
                "tokens": agg.window.tokens,
                "secondsToReset": agg.window.secondsToReset(now: Date()) ?? -1,
            ],
            "cost": [
                "today": agg.cost?.today ?? 0,
                "thisWeek": agg.cost?.thisWeek ?? 0,
                "total": agg.cost?.total ?? 0,
                "unpricedTokens": agg.cost?.unpricedTokens ?? 0,
            ],
            "dominantSurface": agg.dominantSurface.rawValue,
        ]
        // Live block mirrors what the app would headline: the server %, its freshness, and
        // the cap the app would learn from it (cap ≈ window tokens / sessionPct).
        if let l = live {
            var liveOut: [String: Any] = [
                "fresh": l.isFresh(now: Date()),
                "sessionPct": l.sessionPct ?? -1,
                "weeklyPct": l.weeklyPct ?? -1,
            ]
            if let p = l.sessionPct, let cap = calibrateCap(windowTokens: agg.window.tokens, sessionPct: p) {
                liveOut["calibratedCap"] = cap
            }
            out["live"] = liveOut
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        exit(0)
    }
}
