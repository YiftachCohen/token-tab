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
enum Health: Equatable { case healthy, near, throttled, neutral
    var color: Color {
        switch self {
        case .healthy: return Theme.green
        case .near: return Theme.amber
        case .throttled: return Theme.red
        case .neutral: return Theme.green
        }
    }

    /// A single set of quota thresholds for every place that visualizes allowance pressure.
    /// Keeping this here prevents the hero, weekly mini-bar, and status-item ring from giving
    /// the same server percentage three different meanings.
    static func forQuota(usedPct: Int) -> Health {
        switch usedPct {
        case ..<70: return .healthy
        case 70..<90: return .near
        default: return .throttled
        }
    }
}

/// The Claude allowance that should headline. The 5-hour session remains the normal focus;
/// weekly takes over only once it is genuinely near its limit and more pressured than the
/// session. Ties stay session-first because that preserves the shorter-window framing.
struct ClaudeQuota {
    enum Period: Equatable { case session, weekly }
    enum Source: Equatable { case live, cap }

    /// A healthy weekly reading is useful detail, not the primary constraint. This matches the
    /// UI's first warning threshold and prevents an ordinary mid-week percentage from replacing
    /// the more actionable 5-hour pace projection.
    static let weeklyTakeoverFloor = 70

    let pct: Int                 // percent left (the UI's display direction)
    let usedPct: Int             // percent used (pressure/health direction)
    let source: Source
    let period: Period
    let resetText: String?

    /// The helper includes a parenthetical timezone that is useful in diagnostics but too wide
    /// for the menu. Keep the authoritative date/clock and trim only that trailing annotation.
    var displayResetText: String? {
        guard let resetText, !resetText.isEmpty else { return nil }
        if let range = resetText.range(of: " (") { return String(resetText[..<range.lowerBound]) }
        return resetText
    }

    static func liveQuota(_ live: LiveUsage?, period: Period, now: Date) -> ClaudeQuota? {
        guard let live, live.isFresh(now: now) else { return nil }
        let reading: (usedPct: Int?, resetText: String?) = switch period {
        case .session: (live.sessionPct, live.sessionResetText)
        case .weekly:  (live.weeklyPct, live.weeklyResetText)
        }
        guard let usedPct = reading.usedPct else { return nil }
        return quota(usedPct: usedPct, source: .live, period: period,
                     resetText: reading.resetText)
    }

    static func resolve(live: LiveUsage?, window: WindowStats, now: Date) -> ClaudeQuota? {
        let session = liveQuota(live, period: .session, now: now)
        let weekly = liveQuota(live, period: .weekly, now: now)
        if let weekly {
            guard let session else { return weekly }
            return weekly.usedPct >= weeklyTakeoverFloor && weekly.usedPct > session.usedPct
                ? weekly : session
        }
        if let session { return session }

        if let left = window.quotaLeftPercent() {
            let clampedLeft = max(0, min(100, left))
            return ClaudeQuota(pct: clampedLeft, usedPct: 100 - clampedLeft,
                               source: .cap, period: .session, resetText: nil)
        }
        return nil
    }

    private static func quota(usedPct: Int, source: Source, period: Period,
                              resetText: String?) -> ClaudeQuota {
        let used = max(0, min(100, usedPct))
        return ClaudeQuota(pct: 100 - used, usedPct: used, source: source,
                           period: period, resetText: resetText)
    }
}

/// The Bedrock menu-bar metric (design's "MENU BAR SHOWS [$ cost | Tokens]").
enum MenuMetric: String { case cost, tokens }

/// How many providers the menu-bar label shows. `.headline` is the max-pressure rule alone
/// (one glyph + one figure); `.both` puts a glyph+figure pair per provider in the bar, Claude
/// first. `.both` degrades to the headline label whenever only one provider has usage, so a
/// Claude-only Mac never sees an empty second ring. Persisted — unlike `userFocus`, which is
/// an in-session glance, this is a standing preference about the bar's width.
enum MenuBarScope: String { case headline, both }

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
    /// Claude JSONL files walked this refresh.
    var fileCount: Int
    /// Codex JSONL files walked this refresh. Kept separate from `fileCount` so the two
    /// providers' parse health stays attributable; the footer shows the sum, because a
    /// Codex-only Mac reporting "0 files" under a live Codex gauge reads as broken.
    var codexFileCount: Int = 0
    /// Every log file actually read, across providers — the footer's "N files".
    var totalFileCount: Int { fileCount + codexFileCount }
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

    /// The binding Claude quota, resolved down the trust ladder: the fresh 5-hour reading unless
    /// weekly is at least 70% used and more pressured; then the local session cap when live is
    /// unavailable. A lone weekly reading remains authoritative. nil means no honest quota basis.
    func quotaLeft(now: Date) -> ClaudeQuota? {
        ClaudeQuota.resolve(live: live, window: agg.window, now: now)
    }

    /// Claude's authoritative 5-hour allowance even when the weekly allowance is the binding
    /// hero. Kept separate so the detail section can preserve the non-binding limit without
    /// letting it compete visually with the headline.
    func claudeSessionQuota(now: Date) -> ClaudeQuota? {
        ClaudeQuota.liveQuota(live, period: .session, now: now)
    }

    /// The alternate session reading belongs in the detail section only while weekly owns the
    /// hero. Returning nil in every other state prevents two copies of the same session quota.
    func secondaryClaudeSessionQuota(now: Date) -> ClaudeQuota? {
        guard quotaLeft(now: now)?.period == .weekly else { return nil }
        return claudeSessionQuota(now: now)
    }

    func claudeWeeklyQuota(now: Date) -> ClaudeQuota? {
        ClaudeQuota.liveQuota(live, period: .weekly, now: now)
    }

    /// The weekly detail cell is redundant while that same allowance owns the hero.
    func showsWeeklyDetail(now: Date) -> Bool {
        quotaLeft(now: now)?.period != .weekly
    }

    // MARK: - Provider (Codex) helpers — see .context/codex-support-design.md §6

    /// The Codex provider subtotal, present only when Codex records were ingested.
    var codex: ProviderSubtotal? { agg.providers["codex"] }

    /// Codex has real usage worth showing (its section/secondary row is hidden at zero).
    var codexHasUsage: Bool { (codex?.total ?? 0) > 0 }

    /// Claude's own subtotal, when the aggregate has one.
    var claude: ProviderSubtotal? { agg.providers["claude"] }

    /// Whether the combined block may stand in for Claude's.
    ///
    /// It may in exactly one case: an aggregate that predates per-provider subtotals carries
    /// NO buckets at all, and there the combined figures ARE Claude's. It may NOT when the
    /// aggregate has buckets but no Claude one — that is a Codex-only aggregate, where every
    /// combined figure is Codex's and Claude's are a true zero. Falling back there relabels
    /// Codex's tokens and dollars as Claude's, which is the exact mislabelling the whole
    /// per-provider block exists to prevent; it also flips `headlineProvider` to `.claude`
    /// (below) whenever no official Codex window is available, so a Codex-only user gets a
    /// Claude panel showing their Codex usage.
    private var combinedIsClaudes: Bool { agg.providers.isEmpty }

    /// Claude has real usage worth showing — the twin of `codexHasUsage`.
    var claudeHasUsage: Bool { (claude?.total ?? (combinedIsClaudes ? agg.total : 0)) > 0 }

    /// Claude's OWN tokens today. `agg.today` is every provider's added together.
    var claudeToday: Int { claude?.today ?? (combinedIsClaudes ? agg.today : 0) }

    /// Claude's OWN estimated spend today. `agg.cost.today` is every provider's spend added
    /// together, so any figure the UI labels "Claude" has to come from here instead — one
    /// priced Codex record would otherwise inflate it.
    var claudeCostToday: Double {
        claude?.cost?.today ?? (combinedIsClaudes ? (agg.cost?.today ?? 0) : 0)
    }

    /// Claude's OWN burn rate — tokens in the trailing hour. `agg.lastHourTokens` is every
    /// provider's traffic added together, so a busy Codex hour reads as Claude pace: it
    /// inflates the "tok/hr" trend, and (worse) the projections built on it, which measure
    /// that rate against Claude's own 5h cap.
    var claudeLastHourTokens: Int {
        claude?.lastHour ?? (combinedIsClaudes ? agg.lastHourTokens : 0)
    }

    /// Claude's OWN dollars-per-hour, the $ twin of `claudeLastHourTokens`.
    var claudeCostLastHour: Double {
        claude?.cost?.lastHour ?? (combinedIsClaudes ? (agg.cost?.lastHour ?? 0) : 0)
    }

    /// Both providers have usage, so a dual menu-bar label has two real figures to put up.
    /// When this is false, `.both` renders exactly the single headline label it always did.
    var bothProvidersHaveUsage: Bool { claudeHasUsage && codexHasUsage }

    /// Codex's official 5-hour window (`source: "official"`), formatted from the snapshot —
    /// never derived from records. nil when no Codex rate-limits reading exists.
    var codexPrimary: ProviderWindow? { codex?.windows["primary"] }
    /// Codex's official weekly window.
    var codexSecondary: ProviderWindow? { codex?.windows["secondary"] }

    /// The official window the Codex panel can display. Prefer its 5h allowance; fall back to
    /// weekly when that is the only limit OpenAI emitted. The single-label provider ranking
    /// keeps Codex on its primary window per the existing Codex display contract.
    var codexDisplayWindow: ProviderWindow? { codexPrimary ?? codexSecondary }

    /// True once the official window a recorded percentage belongs to has already reset. Past
    /// that instant the number is not "stale but indicative" — it describes a DIFFERENT window,
    /// and OpenAI restarts the new one at 0%. Left unexpired when the snapshot carries no
    /// resetAt (nothing to judge against); `codexStale` is what catches those.
    ///
    /// This matters because Codex logs are only written while Codex runs: stop using Codex for
    /// a day and the last snapshot sits there forever. Without this check a long-gone 92% keeps
    /// winning the menu-bar headline and painting a nearly-full ring, indefinitely.
    private static func expired(_ w: ProviderWindow?, now: Date) -> Bool {
        guard let reset = w?.resetAt else { return false }
        return reset <= now
    }

    /// Codex's official 5h window has outlived the window it was recorded against.
    func codexWindowExpired(now: Date) -> Bool { Self.expired(codexPrimary, now: now) }

    func codexDisplayWindowExpired(now: Date) -> Bool { Self.expired(codexDisplayWindow, now: now) }

    private static func currentUsedPct(_ window: ProviderWindow?, now: Date) -> Int? {
        guard !expired(window, now: now), let p = window?.usedPct else { return nil }
        return max(0, min(100, Int(p.rounded())))
    }

    /// Codex's official 5h "% used" (0…100), rounded — the only REAL Codex percentage, and
    /// only while the window it was recorded against is still open. nil past the reset, so
    /// every caller (headline ranking, ring fraction, figure) falls back to tokens together.
    func codexUsedPct(now: Date) -> Int? {
        Self.currentUsedPct(codexPrimary, now: now)
    }
    /// Codex's official 5h "% left" — the Codex hero gauge fill.
    func codexLeftPct(now: Date) -> Int? { codexUsedPct(now: now).map { 100 - $0 } }

    func codexDisplayUsedPct(now: Date) -> Int? { Self.currentUsedPct(codexDisplayWindow, now: now) }
    func codexDisplayLeftPct(now: Date) -> Int? { codexDisplayUsedPct(now: now).map { 100 - $0 } }

    func codexWeeklyUsedPct(now: Date) -> Int? {
        Self.currentUsedPct(codexSecondary, now: now)
    }

    /// When the official Codex snapshot was captured (newest token_count). Drives the
    /// "as of HH:MM" staleness affordance when older than the freshness window.
    var codexAsOf: Date? { codex?.plan?.asOf }
    var codexPlan: String? { codex?.plan?.planType }

    /// The official Codex % is only as fresh as the newest token_count. Past ~10 min we stop
    /// implying "live" and show a "last known" affordance instead (design §3, §6).
    func codexStale(now: Date, ttl: TimeInterval = 600) -> Bool {
        guard let asOf = codexAsOf else { return codexDisplayUsedPct(now: now) != nil }  // no timestamp ⇒ stale
        return now.timeIntervalSince(asOf) > ttl
    }

    // MARK: - Max-pressure headline (design §6)

    /// Claude's REAL headline pressure (% used), using the session allowance unless weekly has
    /// crossed its takeover floor and is more pressured. Inferred time-left never competes.
    func claudeUsedPct(now: Date) -> Int? {
        quotaLeft(now: now)?.usedPct
    }

    /// The provider the menu-bar/Overview should headline: whichever REAL % is under more
    /// pressure (Codex official %, Claude only with a real cap/live %). If neither has a real
    /// %, fall back to combined today-tokens. Deterministic — recomputed only on the 30s tick.
    func headlineProvider(now: Date) -> Provider {
        let cx = codexHasUsage ? codexUsedPct(now: now) : nil  // Codex official % (real & current)
        let cl = claudeUsedPct(now: now)                     // Claude % only when real
        switch (cl, cx) {
        case let (c?, x?): return x > c ? .codex : .claude   // both real → higher pressure wins
        case (_?, nil):    return .claude
        case (nil, _?):    return .codex
        case (nil, nil):
            // A provider that has no usage AT ALL cannot headline over one that does. Today's
            // tokens alone can't express that: before either has run today the comparison is
            // 0 vs 0, and the tie went to Claude — so a Codex-only user got a Claude-labelled
            // panel every morning until they next ran Codex.
            if codexHasUsage && !claudeHasUsage { return .codex }
            // Then today-tokens decide, each provider's OWN. Reading the COMBINED total as
            // Claude's here is what made a Codex-only aggregate headline `.claude` even mid-
            // session: Claude's figure was Codex's own tokens, so it could never lose.
            let claudeToday = self.claudeToday
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

    /// Persisted: whether the menu bar shows both providers or just the max-pressure headline.
    /// Defaults to `.both` — when two providers are actually in use, showing one of them is
    /// withholding half the reading; the label falls back to a single figure on its own when
    /// only one provider has usage, so this default costs Claude-only users nothing.
    @Published var menuBarScope: MenuBarScope {
        didSet { UserDefaults.standard.set(menuBarScope.rawValue, forKey: "menuBarScope") }
    }

    /// Persisted: whether Codex ingestion is enabled. Feeds the same gate `Config.providerEnabled`
    /// governs — when off, the Codex ingestion branch is skipped entirely (no records, no snapshot),
    /// so the provider vanishes from every view exactly as a missing ~/.codex would. Default on.
    @Published var codexEnabled: Bool {
        didSet {
            UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled")
            userFocus = nil        // a disabled provider can't stay focused
            // Toggling off must also drop the FSEvents stream; toggling on must open one
            // without waiting for a relaunch.
            codexWatcher?.stop(); codexWatcher = nil
            startCodexWatcher()
            refresh()
        }
    }

    /// The user's explicit Overview focus (tapping a secondary row). nil = auto (max-pressure
    /// on the 30s tick). Not persisted: focus is an in-session glance choice, not a setting.
    @Published var userFocus: Provider?

    /// Whether the resolved Codex root was actually readable on the last refresh (independent of
    /// the toggle). NOT "does ~/.codex exist": under the sandbox that question is unanswerable
    /// without a scope, so this is false until access is granted — the Settings copy has to say
    /// "read access needed", not "not found".
    @Published private(set) var codexReadable = false

    /// The providers this refresh ACTUALLY read, as resolved by the same gates the ingestion
    /// branches use (dir present + `Config.providerEnabled`, i.e. `TOKENTAB_PROVIDERS`, plus the
    /// Codex Settings toggle). The trust footer is a claim about what this app touched, so it has
    /// to be derived from these rather than re-guessed: with `TOKENTAB_PROVIDERS=codex` the old
    /// footer still named ~/.claude, a directory that refresh never opened.
    @Published private(set) var claudeActive = false
    @Published private(set) var codexActive = false

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
    /// A second FSEvents stream on the Codex root. Without it, Codex-only activity waited for
    /// the 90s safety refresh on a 30s timer — up to two minutes of a visibly stale Codex
    /// gauge while Claude's updated instantly. Torn down and rebuilt when the toggle flips.
    private var codexWatcher: FolderWatcher?
    private var displayTimer: Timer?
    private var lastRefresh = Date.distantPast
    /// Set by every refresh, cleared by the idle reclaim (see `reclaimFreedPages`). Reclaiming
    /// mid-burst is wasted work — the next refresh in the burst faults the same pages straight
    /// back in — so the reclaim waits for the activity to stop instead.
    private var needsReclaim = false
    /// How long the logs must be quiet before reclaiming. Comfortably inside the 30s tick, so
    /// the drop lands on the first tick after a session goes idle.
    private let reclaimIdleDelay: TimeInterval = 25
    /// Set when a refresh is requested while one is already in flight. The
    /// completing refresh re-runs once if this is set, so the final write of a
    /// burst is never dropped (the old guard silently discarded it, leaving
    /// counts stale until the 90s safety tick).
    private var pendingRefresh = false
    private var logDirProvider: () -> URL?
    /// The Codex root to read, from the same AccessManager that owns the Claude one — so the
    /// directory we ingest is the directory the user actually granted, not a path we assume.
    private var codexDirProvider: () -> URL?
    /// Re-parses only the files that changed since the last refresh (keyed by mtime+size),
    /// so an active session's constant FSEvents bursts don't re-read the whole history — and
    /// persists across launches, so a cold start re-parses only what changed rather than the
    /// whole log history (the slow first read that left the loading screen up for seconds).
    private let recordCache = RecordCache(storeURL: RecordCache.defaultStoreURL())

    init(logDir: @escaping () -> URL?,
         codexDir: @escaping () -> URL? = { CodexLogReader.defaultCodexRoot() }) {
        self.logDirProvider = logDir
        self.codexDirProvider = codexDir
        let raw = UserDefaults.standard.string(forKey: "menuMetric") ?? MenuMetric.cost.rawValue
        self.menuMetric = MenuMetric(rawValue: raw) ?? .cost
        let scopeRaw = UserDefaults.standard.string(forKey: "menuBarScope") ?? MenuBarScope.both.rawValue
        self.menuBarScope = MenuBarScope(rawValue: scopeRaw) ?? .both
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
        startCodexWatcher()
        refresh()
    }

    /// Call after the user grants folder access (either dir becomes readable).
    func accessChanged() {
        startWatcher()
        startCodexWatcher()
        refresh()
    }

    func stop() {
        displayTimer?.invalidate(); displayTimer = nil
        watcher?.stop(); watcher = nil
        codexWatcher?.stop(); codexWatcher = nil
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

    /// The same event-driven read for the Codex root, so a Codex turn updates the bar as
    /// promptly as a Claude one. Gated on the same two conditions as ingestion (the Settings
    /// toggle AND the env/dir gate), so a disabled or absent provider opens no stream at all.
    private func startCodexWatcher() {
        guard codexWatcher == nil, codexEnabled, let root = codexDirProvider() else { return }
        guard FileManager.default.fileExists(atPath: root.path),
              Config.providerEnabled("codex", dirExists: true) else { return }
        let w = FolderWatcher(path: root.path) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // Only keep it if the stream actually started. Under the sandbox this fails until
        // ~/.codex is granted, and holding a dead watcher would make the `codexWatcher == nil`
        // guard above swallow every later retry — so the grant would never wire up a watcher
        // until the next launch. (The 90s safety refresh covers the gap meanwhile.)
        guard w.start() else { return }
        codexWatcher = w
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
        let idleFor = Date().timeIntervalSince(lastRefresh)
        if idleFor > 90 { refresh() }
        else if needsReclaim, idleFor > reclaimIdleDelay {
            needsReclaim = false
            Task.detached(priority: .utility) { Self.reclaimFreedPages() }
        }
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
        let codexDir = codexDirProvider()         // @MainActor access state, same as `dir` above
        Task.detached(priority: .utility) {
            let now0 = Date()
            // Claude is provider-gated too, on the same TOKENTAB_PROVIDERS list the CLI honors —
            // otherwise `TOKENTAB_PROVIDERS=codex` means one thing in the CLI and another in the
            // app, and the app's trust footer would name a directory it never opened. The dir is
            // the granted one, so it exists by construction.
            let claudeOn = Config.providerEnabled("claude", dirExists: true)
            let files = claudeOn ? LogReader.findJSONL(in: dir) : []
            // One array, sized once for BOTH providers' cached records: the per-refresh flat
            // copy is ~13 MB on a real history, and growing it from empty (then duplicating it
            // copy-on-write to append Codex) left tens of MB of freed-but-retained pages.
            var records: [UsageRecord] = []
            records.reserveCapacity(cache.cachedRecordCount())
            var malformed = 0
            if claudeOn {
                malformed = cache.appendRecords(for: files, into: &records)
            }

            // Codex ingestion (provider-gated). Default = every provider whose dir exists; an
            // explicit TOKENTAB_PROVIDERS list overrides. Records merge into the same pool; the
            // official rate_limits snapshot rides out-of-band into AggregateOptions (formatting
            // only, never summed). A missing/unreadable ~/.codex is silently skipped.
            var codexRateLimits: CodexRateLimitsSnapshot? = nil
            var codexFileCount = 0
            // nil root = no access resolved yet (sandboxed, ~/.codex not granted) → nothing to read.
            let codexReadable = codexDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            // The Settings toggle is the sandbox-clean gate (UserDefaults); it AND the existing
            // env/dir gate must both allow Codex before we ingest a single line.
            // `codexDir != nil` is part of the gate, not just a guard: an explicit
            // TOKENTAB_PROVIDERS=codex makes providerEnabled true regardless of the dir, and
            // codexActive is what the trust footer names — it must never claim a directory we
            // never opened.
            let codexActive = codexOn && codexDir != nil
                && Config.providerEnabled("codex", dirExists: codexReadable)
            if codexActive, let codexRoot = codexDir {
                let codexFiles = CodexLogReader.findCodexJSONL(in: codexRoot)
                codexFileCount = codexFiles.count
                let cx = cache.appendCodexRecords(for: codexFiles, into: &records)
                malformed += cx.malformed
                codexRateLimits = cx.codexRateLimits
            }

            // Both providers counted; freeze to `let`s so the MainActor hop below captures
            // values rather than still-mutable vars (an error in the Swift 6 language mode).
            let malformedTotal = malformed
            let codexFileTotal = codexFileCount

            // One dedup pass feeds both the aggregate and the history series (60 days covers
            // the 30-day range plus its prior 30-day comparison period). Running them
            // separately deduped the whole history twice per refresh for identical results —
            // two ~38 MB transient maps where one ~11 MB map does.
            let (agg, history) = aggregateWithHistory(
                records,
                options: AggregateOptions(now: now0, cap: cap, codexRateLimits: codexRateLimits),
                historyDays: 60,
                costModel: Pricing())
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
                                         fileCount: files.count, codexFileCount: codexFileTotal,
                                         malformed: malformedTotal,
                                         lastUpdated: now, cap: cap, live: live, history: history)
                // Learn the cap from a fresh live reading (cap ≈ tokens / sessionPct) so a real
                // % survives once live goes stale. Takes effect on the next refresh's cap.
                // Admissibility — freshness AND same-block membership — lives in Core's
                // `calibrateCap(from:window:now:)`, which `--probe` calls too, so the
                // diagnostic can never advertise a cap this loop would refuse to learn.
                if let l = live,
                   let learned = calibrateCap(from: l, window: agg.window, now: now),
                   learned != self.calibratedCap {
                    self.calibratedCap = learned
                }
                self.codexReadable = codexReadable
                self.claudeActive = claudeOn
                self.codexActive = codexActive
                self.isRefreshing = false
                self.hasLoadedOnce = true
                self.lastRefresh = now
                self.needsReclaim = true
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

    /// Return malloc's freed-but-retained pages to the OS. `nil` means every zone; a `goal` of
    /// 0 means "release what you can" rather than a target byte count. Purely an allocator
    /// hint — it touches no app state, so it is safe from any thread.
    ///
    /// This app allocates in bursts (parse + aggregate a long history) and then sits idle for
    /// minutes. malloc holds the freed pages on its free list rather than returning them, so
    /// what Activity Monitor reports at rest is the high-water mark of the last refresh, not
    /// what the app is actually holding — tens of MB of `MALLOC_LARGE (empty)`. Called once the
    /// logs go quiet, this makes idle footprint track live data.
    private nonisolated static func reclaimFreedPages() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Health is a real throttle signal only when we have a usage % — a fresh live reading
    /// (preferred) or the cap-based token %. Without either we never invent danger (green).
    private static func health(for agg: Aggregate, live: LiveUsage?, now: Date, mode: Mode) -> Health {
        guard mode == .subscription else { return .neutral }
        guard let quota = ClaudeQuota.resolve(live: live, window: agg.window, now: now) else {
            return .neutral
        }
        return Health.forQuota(usedPct: quota.usedPct)
    }
}
