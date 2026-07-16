// Token Tab — a headless `--probe` mode.
//
// Runs the exact same read + aggregate the menu bar uses and prints the totals as JSON,
// then exits before any UI starts. Two uses: (1) reconcile the native engine against the
// audited JS engine (`node ../src/token-tab.mjs --json`) on real logs, and (2) let a
// skeptic see precisely which numbers the app derives. Reads the default log dir
// directly (no sandbox), so run the bare binary, not the sandboxed .app.

import Foundation
import ServiceManagement
import TokenTabCore

enum Probe {
    static func runIfRequested() {
        runHelperProbeIfRequested()
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

    /// `--probe-helper`: print exactly what LiveHelperManager would observe — the bundle
    /// path, whether the agent plist is visible from inside the (possibly sandboxed)
    /// process, and SMAppService's raw status — then exit. Diagnoses "Live % toggle
    /// thinks it's a dev build" without clicking through the UI.
    private static func runHelperProbeIfRequested() {
        guard CommandLine.arguments.contains(where: { $0.hasPrefix("--probe-helper") }) else { return }
        let bundleURL = Bundle.main.bundleURL
        let plist = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(LiveHelperManager.plistName)
        let service = SMAppService.agent(plistName: LiveHelperManager.plistName)
        var out: [String: Any] = [
            "bundleURL": bundleURL.path,
            "bundlePathExtension": bundleURL.pathExtension,
            "plistPath": plist.path,
            "plistExists": FileManager.default.fileExists(atPath: plist.path),
            "smStatusRaw": service.status.rawValue,   // 0 notRegistered · 1 enabled · 2 requiresApproval · 3 notFound
        ]
        // `--probe-helper-register`: additionally try the actual register → report the
        // error (or success + new status), then unregister to leave launchd unchanged.
        if CommandLine.arguments.contains("--probe-helper-register") {
            do {
                try service.register()
                out["register"] = "ok"
                out["smStatusAfter"] = service.status.rawValue
                try? service.unregister()
            } catch {
                out["register"] = "threw: \((error as NSError).domain) \((error as NSError).code) — \(error.localizedDescription)"
                out["smStatusAfter"] = service.status.rawValue
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
            // Also drop the result in the (container) temp dir, so the probe is readable
            // when the app is launched via `open` and stdout goes nowhere.
            let drop = FileManager.default.temporaryDirectory.appendingPathComponent("token-tab-helper-probe.json")
            try? data.write(to: drop)
        }
        exit(0)
    }
}
