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

/// Which provider the Overview panel/menu-bar headline is focused on. Claude and Codex
/// are the two providers Token Tab reads; the app is Claude-first, so `.claude` is the
/// structural default. `.codex` renders the Codex hero gauge (official 5h %).
enum Provider: String, CaseIterable { case claude, codex

    var key: String { rawValue }

    /// Display accent per DESIGN.md: Claude keeps its green/amber-by-surface semantics
    /// (green here, the panel refines it), Codex is the indigo token.
    var accent: Color {
        switch self {
        case .claude: return Theme.green
        case .codex:  return Theme.indigo
        }
    }
}

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

    // MARK: - Provider (Codex) helpers — see .context/codex-support-design.md §6

    /// The Codex provider subtotal, present only when Codex records were ingested.
    var codex: ProviderSubtotal? { agg.providers["codex"] }

    /// Codex has real usage worth showing (its section/secondary row is hidden at zero).
    var codexHasUsage: Bool { (codex?.total ?? 0) > 0 }

    /// Codex's official 5-hour window (`source: "official"`), formatted from the snapshot —
    /// never derived from records. nil when no Codex rate-limits reading exists.
    var codexPrimary: ProviderWindow? { codex?.windows["primary"] }
    /// Codex's official weekly window.
    var codexSecondary: ProviderWindow? { codex?.windows["secondary"] }

    /// Codex's official 5h "% used" (0…100), rounded — the only REAL Codex percentage.
    var codexUsedPct: Int? {
        guard let p = codexPrimary?.usedPct else { return nil }
        return max(0, min(100, Int(p.rounded())))
    }
    /// Codex's official 5h "% left" — the Codex hero gauge fill.
    var codexLeftPct: Int? { codexUsedPct.map { 100 - $0 } }
    var codexWeeklyUsedPct: Int? {
        guard let p = codexSecondary?.usedPct else { return nil }
        return max(0, min(100, Int(p.rounded())))
    }

    /// When the official Codex snapshot was captured (newest token_count). Drives the
    /// "as of HH:MM" staleness affordance when older than the freshness window.
    var codexAsOf: Date? { codex?.plan?.asOf }
    var codexPlan: String? { codex?.plan?.planType }

    /// The official Codex % is only as fresh as the newest token_count. Past ~10 min we stop
    /// implying "live" and show a "last known" affordance instead (design §3, §6).
    func codexStale(now: Date, ttl: TimeInterval = 600) -> Bool {
        guard let asOf = codexAsOf else { return codexUsedPct != nil }   // no timestamp ⇒ treat as stale
        return now.timeIntervalSince(asOf) > ttl
    }

    // MARK: - Max-pressure headline (design §6)

    /// Claude's REAL headline pressure (% used), only when it has an authoritative basis: a
    /// FRESH live reading or a configured/calibrated cap. Inferred time-left is NOT a real %
    /// and never competes — nil in that case, so the ranking falls back to today-tokens.
    func claudeUsedPct(now: Date) -> Int? {
        if let l = live, l.isFresh(now: now), let p = l.sessionPct { return max(0, min(100, p)) }
        if let p = agg.window.tokenPct { return max(0, min(100, p)) }
        return nil
    }

    /// The provider the menu-bar/Overview should headline: whichever REAL % is under more
    /// pressure (Codex official %, Claude only with a real cap/live %). If neither has a real
    /// %, fall back to combined today-tokens. Deterministic — recomputed only on the 30s tick.
    func headlineProvider(now: Date) -> Provider {
        let cx = codexHasUsage ? codexUsedPct : nil          // Codex official % (real)
        let cl = claudeUsedPct(now: now)                     // Claude % only when real
        switch (cl, cx) {
        case let (c?, x?): return x > c ? .codex : .claude   // both real → higher pressure wins
        case (_?, nil):    return .claude
        case (nil, _?):    return .codex
        case (nil, nil):
            // No real % anywhere → combined today-tokens decides (current behavior extended).
            let claudeToday = agg.providers["claude"]?.today ?? agg.today
            let codexToday  = codex?.today ?? 0
            return (codexHasUsage && codexToday > claudeToday) ? .codex : .claude
        }
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

    /// Persisted: whether Codex ingestion is enabled. Feeds the same gate `Config.providerEnabled`
    /// governs — when off, the Codex ingestion branch is skipped entirely (no records, no snapshot),
    /// so the provider vanishes from every view exactly as a missing ~/.codex would. Default on.
    @Published var codexEnabled: Bool {
        didSet {
            UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled")
            userFocus = nil        // a disabled provider can't stay focused
            refresh()
        }
    }

    /// The user's explicit Overview focus (tapping a secondary row). nil = auto (max-pressure
    /// on the 30s tick). Not persisted: focus is an in-session glance choice, not a setting.
    @Published var userFocus: Provider?

    /// Whether ~/.codex exists on disk (independent of the toggle) — drives the Settings grant
    /// row and the trust footer's "+ ~/.codex" clause. Refreshed alongside the aggregate.
    @Published private(set) var codexDirExists = false

    /// The provider the Overview/menu-bar headlines right now: the user's explicit tap wins,
    /// else the auto max-pressure ranking. Codex is only ever focusable when it has usage.
    func focused(now: Date) -> Provider {
        if let f = userFocus, f == .claude || snapshot.codexHasUsage { return f }
        return snapshot.headlineProvider(now: now)
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

    /// Persisted: the user's explicit display-mode choice from Settings. nil = auto-detect.
    /// This is the sandbox-clean override (UserDefaults), since the app can't read the
    /// env file under its read-only grant. Empty string in defaults means "auto".
    @Published var surfaceModeOverride: Surface? {
        didSet {
            UserDefaults.standard.set(surfaceModeOverride?.rawValue ?? "", forKey: "surfaceMode")
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
    /// Set when a refresh is requested while one is already in flight. The
    /// completing refresh re-runs once if this is set, so the final write of a
    /// burst is never dropped (the old guard silently discarded it, leaving
    /// counts stale until the 90s safety tick).
    private var pendingRefresh = false
    private var logDirProvider: () -> URL?
    /// Re-parses only the files that changed since the last refresh (keyed by mtime+size),
    /// so an active session's constant FSEvents bursts don't re-read the whole history — and
    /// persists across launches, so a cold start re-parses only what changed rather than the
    /// whole log history (the slow first read that left the loading screen up for seconds).
    private let recordCache = RecordCache(storeURL: RecordCache.defaultStoreURL())

    init(logDir: @escaping () -> URL?) {
        self.logDirProvider = logDir
        let raw = UserDefaults.standard.string(forKey: "menuMetric") ?? MenuMetric.cost.rawValue
        self.menuMetric = MenuMetric(rawValue: raw) ?? .cost
        self.capOverride = UserDefaults.standard.integer(forKey: "windowCap")        // 0 when unset
        self.calibratedCap = UserDefaults.standard.integer(forKey: "calibratedCap")  // 0 when unset
        // Codex defaults ON (mirrors the "provider whose dir exists is on" default); an
        // explicit `false` in defaults is the only way it's off (once the user toggled it).
        self.codexEnabled = (UserDefaults.standard.object(forKey: "codexEnabled") as? Bool) ?? true
        let modeRaw = UserDefaults.standard.string(forKey: "surfaceMode") ?? ""
        self.surfaceModeOverride = Surface(rawValue: modeRaw)   // nil for "" / unknown → auto
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
        if isRefreshing { pendingRefresh = true; return }
        isRefreshing = true
        pendingRefresh = false
        let cap = effectiveCap
        let cache = recordCache
        let forceBedrock = Config.useBedrock
        let inAppOverride = surfaceModeOverride   // @MainActor state, captured before detaching
        let codexOn = codexEnabled                // the Settings toggle, captured before detaching
        Task.detached(priority: .utility) {
            let now0 = Date()
            let files = LogReader.findJSONL(in: dir)
            var (records, malformed) = cache.records(for: files)

            // Codex ingestion (provider-gated). Default = every provider whose dir exists; an
            // explicit TOKENTAB_PROVIDERS list overrides. Records merge into the same pool; the
            // official rate_limits snapshot rides out-of-band into AggregateOptions (formatting
            // only, never summed). A missing/unreadable ~/.codex is silently skipped.
            var codexRateLimits: CodexRateLimitsSnapshot? = nil
            let codexRoot = CodexLogReader.defaultCodexRoot()
            let codexDirExists = FileManager.default.fileExists(atPath: codexRoot.path)
            // The Settings toggle is the sandbox-clean gate (UserDefaults); it AND the existing
            // env/dir gate must both allow Codex before we ingest a single line.
            if codexOn, Config.providerEnabled("codex", dirExists: codexDirExists) {
                let codexFiles = CodexLogReader.findCodexJSONL(in: codexRoot)
                let cx = cache.codexRecords(for: codexFiles)
                records.append(contentsOf: cx.records)
                malformed += cx.malformed
                codexRateLimits = cx.codexRateLimits
            }

            // Both providers counted; freeze to a `let` so the MainActor hop below captures a
            // value rather than a still-mutable var (an error in the Swift 6 language mode).
            let malformedTotal = malformed

            let agg = aggregate(records,
                                options: AggregateOptions(now: now0, cap: cap, codexRateLimits: codexRateLimits),
                                costModel: Pricing())
            // 60 days covers the 30-day range plus its prior 30-day comparison period.
            let history = dailyHistory(records, days: 60, now: now0, costModel: Pricing())
            let live = LiveReader.read(logDir: dir)   // opt-in cache; nil when no sidecar runs
            let override = Config.surfaceOverride
            await MainActor.run {
                let now = Date()
                // Surface precedence: an in-app choice wins (the only sandbox-reachable override);
                // else an explicit TOKENTAB_MODE; else CLAUDE_CODE_USE_BEDROCK forces Bedrock (logs
                // bare claude-* ids otherwise read as a subscription); else the dominant model-id
                // surface. mode follows: anything non-subscription is burn.
                let surface = resolveSurface(inApp: inAppOverride,
                                             envOverride: override,
                                             forceBedrock: forceBedrock,
                                             dominant: agg.dominantSurface)
                let mode: Mode = surface == .subscription ? .subscription : .burn
                let health = Self.health(for: agg, live: live, now: now, mode: mode)
                self.snapshot = Snapshot(agg: agg, mode: mode, surface: surface, health: health,
                                         fileCount: files.count, malformed: malformedTotal,
                                         lastUpdated: now, cap: cap, live: live, history: history)
                // Learn the cap from a fresh live reading (cap ≈ tokens / sessionPct) so a real
                // % survives once live goes stale. Takes effect on the next refresh's cap.
                if let l = live, l.isFresh(now: now), let p = l.sessionPct,
                   let learned = calibrateCap(windowTokens: agg.window.tokens, sessionPct: p),
                   learned != self.calibratedCap {
                    self.calibratedCap = learned
                }
                self.codexDirExists = codexDirExists
                self.isRefreshing = false
                self.hasLoadedOnce = true
                self.lastRefresh = now
                self.clock = now
                // A change landed while we were reading — run exactly once more to
                // pick it up (further bursts are coalesced by the watcher's debounce).
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
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
