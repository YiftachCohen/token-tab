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
    /// detected dominant surface; a TOKENTAB_MODE override replaces it.
    var surface: Surface
    var health: Health
    var fileCount: Int
    var malformed: Int
    var lastUpdated: Date
    var cap: Int

    static let empty = Snapshot(agg: Aggregate(), mode: .burn, surface: .untracked, health: .neutral,
                                fileCount: 0, malformed: 0, lastUpdated: .distantPast, cap: 0)
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

    private var watcher: FolderWatcher?
    private var displayTimer: Timer?
    private var lastRefresh = Date.distantPast
    private var logDirProvider: () -> URL?

    init(logDir: @escaping () -> URL?) {
        self.logDirProvider = logDir
        let raw = UserDefaults.standard.string(forKey: "menuMetric") ?? MenuMetric.cost.rawValue
        self.menuMetric = MenuMetric(rawValue: raw) ?? .cost
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
        let cap = Config.windowCap
        Task.detached(priority: .utility) {
            let files = LogReader.findJSONL(in: dir)
            let (records, malformed) = LogReader.readRecords(from: files)
            let agg = aggregate(records,
                                options: AggregateOptions(cap: cap),
                                costModel: Pricing())
            let override = Config.surfaceOverride
            await MainActor.run {
                // TOKENTAB_MODE wins; otherwise the dominant model-id surface decides.
                let surface = override ?? agg.dominantSurface
                let mode: Mode = surface == .subscription ? .subscription : .burn
                let health = Self.health(for: agg, mode: mode)
                self.snapshot = Snapshot(agg: agg, mode: mode, surface: surface, health: health,
                                         fileCount: files.count, malformed: malformed,
                                         lastUpdated: Date(), cap: cap)
                self.isRefreshing = false
                self.hasLoadedOnce = true
                self.lastRefresh = Date()
                self.clock = Date()
            }
        }
    }

    /// Health is a real throttle signal only when we have a cap (token % of the window).
    /// Without a cap we never invent danger — the dot stays green.
    private static func health(for agg: Aggregate, mode: Mode) -> Health {
        guard mode == .subscription, let pct = agg.window.tokenPct else { return .neutral }
        switch pct {
        case ..<70: return .healthy
        case 70..<90: return .near
        default: return .throttled
        }
    }
}
