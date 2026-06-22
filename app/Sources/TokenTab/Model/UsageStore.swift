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
    var health: Health
    var fileCount: Int
    var malformed: Int
    var lastUpdated: Date
    var cap: Int

    static let empty = Snapshot(agg: Aggregate(), mode: .burn, health: .neutral,
                                fileCount: 0, malformed: 0, lastUpdated: .distantPast, cap: 0)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot = .empty
    @Published var isRefreshing = false
    @Published var hasLoadedOnce = false

    /// Persisted: which metric the Bedrock menu bar shows.
    @Published var menuMetric: MenuMetric {
        didSet { UserDefaults.standard.set(menuMetric.rawValue, forKey: "menuMetric") }
    }

    private var timer: Timer?
    private var logDirProvider: () -> URL?

    init(logDir: @escaping () -> URL?) {
        self.logDirProvider = logDir
        let raw = UserDefaults.standard.string(forKey: "menuMetric") ?? MenuMetric.cost.rawValue
        self.menuMetric = MenuMetric(rawValue: raw) ?? .cost
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

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
            await MainActor.run {
                let mode: Mode = agg.dominantSurface == .subscription ? .subscription : .burn
                let health = Self.health(for: agg, mode: mode)
                self.snapshot = Snapshot(agg: agg, mode: mode, health: health,
                                         fileCount: files.count, malformed: malformed,
                                         lastUpdated: Date(), cap: cap)
                self.isRefreshing = false
                self.hasLoadedOnce = true
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
