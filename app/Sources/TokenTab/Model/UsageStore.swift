// Token Tab — the observable that drives the UI.
//
// Reads the logs off the main actor, runs the pure aggregator, and publishes a Snapshot.
// Refreshes on a light timer and whenever the menu opens. No network; the only thing it
// touches is the granted ~/.claude directory via LogReader.

import Foundation
import SwiftUI
import TokenTabCore

/// What the dropdown's headline is — decided by the dominant surface, not a toggle.
enum Mode { case subscription, burn }

/// Menu-bar health dot (the readability study's "accent dot" signal).
enum Health { case healthy, near, throttled, neutral
    var color: Color {
        switch self {
        case .healthy: return Theme.green
        case .near: return Theme.amber
        case .throttled: return Theme.red
        case .neutral: return Theme.green
        }
    }
}

/// The Bedrock menu-bar metric (design's "MENU BAR SHOWS [$ cost | Tokens]").
enum MenuMetric: String { case cost, tokens }

struct Snapshot {
    var agg: Aggregate
    var mode: Mode
    /// The surface the UI actually renders (drives the header pill). Normally the auto-
    /// detected dominant surface; a TOKENTAB_MODE override — or the CLAUDE_CODE_USE_BEDROCK
    /// flag — replaces it (the logs alone can't tell Bedrock from a subscription).
    var surface: Surface
    var health: Health
    var fileCount: Int
    var malformed: Int
    var lastUpdated: Date
    var cap: Int
    var live: LiveUsage?
    /// Contiguous per-day usage ending today (60 days) — the History tab's series. Computed
    /// off-main alongside `agg`; the view slices the last 7/14/30 and the prior period for it.
    var history: [DayUsage] = []

    static let empty = Snapshot(agg: Aggregate(), mode: .burn, surface: .untracked, health: .neutral,
                                fileCount: 0, malformed: 0, lastUpdated: .distantPast, cap: 0, live: nil,
                                history: [])

    /// The headline quota %, resolved down the trust ladder: a FRESH live reading first (the
    /// real server number), then a cap-based % (manual or live-calibrated). nil → no quota
    /// basis at all, so the UI shows the honest time countdown. `source` lets the UI label it.
    func quotaLeft(now: Date) -> (pct: Int, source: String)? {
        if let l = live, l.isFresh(now: now), let p = l.sessionPct {
            return (max(0, min(100, 100 - p)), "live")
        }
        if let p = agg.window.quotaLeftPercent() { return (p, "cap") }
        return nil
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot = .empty
    @Published var isRefreshing = false
    @Published var hasLoadedOnce = false
    /// A coarse clock so time-derived UI (the menu-bar runway %) keeps ticking while idle,
    /// without re-reading any files. The dropdown ticks faster (1s) only while it's open.
    @Published var clock = Date()

    /// Persisted: which metric the Bedrock menu bar shows.
    @Published var menuMetric: MenuMetric {
        didSet { UserDefaults.standard.set(menuMetric.rawValue, forKey: "menuMetric") }
    }

    /// Persisted: the user's 5-hour token cap, set from the dropdown. 0 = unset. This is the
    /// sandbox-clean way to "set a cap locally" — UserDefaults, no dotfile to hand-edit.
    /// Changing it re-aggregates, which flips the runway from a time countdown to a real
    /// quota %. Env/dotfile `TOKENTAB_WINDOW_CAP` still works as a fallback (see effectiveCap).
    @Published var capOverride: Int {
        didSet {
            UserDefaults.standard.set(capOverride, forKey: "windowCap")
            refresh()
        }
    }

    /// Persisted: the cap LEARNED from a live reading (cap ≈ window tokens / sessionPct). Set
    /// only during refresh, never typed by the user. Persisting it is what lets the gauge keep
    /// showing a real % after the live reading goes stale or the sidecar stops.
    @Published var calibratedCap: Int {
        didSet { UserDefaults.standard.set(calibratedCap, forKey: "calibratedCap") }
    }

    /// The cap fed to the aggregator, by precedence: a manual override wins (explicit intent),
    /// then the live-calibrated cap, then env/dotfile config.
    var effectiveCap: Int {
        if capOverride > 0 { return capOverride }
        if calibratedCap > 0 { return calibratedCap }
        return Config.windowCap
    }

    private var watcher: FolderWatcher?
    private var displayTimer: Timer?
    private var lastRefresh = Date.distantPast
    private var logDirProvider: () -> URL?
    /// Re-parses only the files that changed since the last refresh (keyed by mtime+size),
    /// so an active session's constant FSEvents bursts don't re-read the whole history.
    private let recordCache = RecordCache()

    init(logDir: @escaping () -> URL?) {
        self.logDirProvider = logDir
        let raw = UserDefaults.standard.string(forKey: "menuMetric") ?? MenuMetric.cost.rawValue
        self.menuMetric = MenuMetric(rawValue: raw) ?? .cost
        self.capOverride = UserDefaults.standard.integer(forKey: "windowCap")        // 0 when unset
        self.calibratedCap = UserDefaults.standard.integer(forKey: "calibratedCap")  // 0 when unset
    }

    func start() {
        startDisplayTimer()
        startWatcher()
        refresh()
    }

    /// Call after the user grants folder access (logDir becomes available).
    func accessChanged() {
        startWatcher()
        refresh()
    }

    func stop() {
        displayTimer?.invalidate(); displayTimer = nil
        watcher?.stop(); watcher = nil
    }

    /// File reads are event-driven: FSEvents fires only when ~/.claude actually changes,
    /// so there's no idle polling. (If the stream can't start — e.g. under an unusual
    /// sandbox — the 90s safety refresh below still keeps data fresh.)
    private func startWatcher() {
        guard watcher == nil, let dir = logDirProvider() else { return }
        let w = FolderWatcher(path: dir.path) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        w.start()
        watcher = w
    }

    /// 30s clock tick: pure arithmetic (advances the runway display), with a low-frequency
    /// safety refresh in case a file change was ever missed. No per-tick disk walk.
    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        clock = Date()
        if Date().timeIntervalSince(lastRefresh) > 90 { refresh() }
    }

    func refresh() {
        guard let dir = logDirProvider() else { return }
        if isRefreshing { return }
        isRefreshing = true
        let cap = effectiveCap
        let cache = recordCache
        let forceBedrock = Config.useBedrock
        Task.detached(priority: .utility) {
            let now0 = Date()
            let files = LogReader.findJSONL(in: dir)
            let (records, malformed) = cache.records(for: files)
            let agg = aggregate(records,
                                options: AggregateOptions(now: now0, cap: cap),
                                costModel: Pricing())
            // 60 days covers the 30-day range plus its prior 30-day comparison period.
            let history = dailyHistory(records, days: 60, now: now0, costModel: Pricing())
            let live = LiveReader.read(logDir: dir)   // opt-in cache; nil when no sidecar runs
            let override = Config.surfaceOverride
            await MainActor.run {
                let now = Date()
                // Surface precedence: an explicit TOKENTAB_MODE wins; else CLAUDE_CODE_USE_BEDROCK
                // forces Bedrock (logs bare claude-* ids otherwise read as a subscription); else
                // the dominant model-id surface. mode follows: anything non-subscription is burn.
                let surface = override ?? (forceBedrock ? .bedrock : agg.dominantSurface)
                let mode: Mode = surface == .subscription ? .subscription : .burn
                let health = Self.health(for: agg, live: live, now: now, mode: mode)
                self.snapshot = Snapshot(agg: agg, mode: mode, surface: surface, health: health,
                                         fileCount: files.count, malformed: malformed,
                                         lastUpdated: now, cap: cap, live: live, history: history)
                // Learn the cap from a fresh live reading (cap ≈ tokens / sessionPct) so a real
                // % survives once live goes stale. Takes effect on the next refresh's cap.
                if let l = live, l.isFresh(now: now), let p = l.sessionPct,
                   let learned = calibrateCap(windowTokens: agg.window.tokens, sessionPct: p),
                   learned != self.calibratedCap {
                    self.calibratedCap = learned
                }
                self.isRefreshing = false
                self.hasLoadedOnce = true
                self.lastRefresh = now
                self.clock = now
            }
        }
    }

    /// Health is a real throttle signal only when we have a usage % — a fresh live reading
    /// (preferred) or the cap-based token %. Without either we never invent danger (green).
    private static func health(for agg: Aggregate, live: LiveUsage?, now: Date, mode: Mode) -> Health {
        guard mode == .subscription else { return .neutral }
        let used: Int? = (live?.isFresh(now: now) == true ? live?.sessionPct : nil) ?? agg.window.tokenPct
        guard let pct = used else { return .neutral }
        switch pct {
        case ..<70: return .healthy
        case 70..<90: return .near
        default: return .throttled
        }
    }
}
