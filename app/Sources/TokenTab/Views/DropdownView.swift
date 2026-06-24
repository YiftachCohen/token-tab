// Token Tab — the dropdown shell.
//
// Glass chrome + a header, then the mode-specific panel (runway vs burn), then a slim
// action row. The headline is decided by the dominant surface (subscription → runway,
// pay-per-token → burn), not a user toggle — "decided by your plan."

import SwiftUI
import TokenTabCore

/// Header: brand chip + "Token Tab" + the mode pill.
struct PanelHeader<P: View>: View {
    let pill: P
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex8: 0x26272E), Color(hex8: 0x15161B)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    BrandMark(size: 11, lineWidth: 2.4, fraction: 0.63, color: Theme.green)
                }
                Text("Token Tab").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Spacer()
            pill
        }
        .padding(.horizontal, 17).padding(.top, 14)
    }
}

/// Root content: grant flow → loading → the active mode panel, all inside glass chrome.
struct DropdownView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var access: AccessManager
    @Environment(\.colorScheme) private var scheme
    /// Settings (cap + live) live behind the gear so they're reachable in EVERY mode — the
    /// burn/API/Bedrock panel has no quota gauge to host them inline.
    @State private var showSettings = false
    /// Overview ↔ History, the design's tab switcher. Shared across both modes; the header
    /// and footer sit outside it so only the body swaps.
    @State private var tab: PanelTab = .overview

    var body: some View {
        Group {
            switch access.state {
            case .needsGrant:
                GrantView(access: access, store: store)
            case .resolving:
                loading
            case .granted, .directRead:
                if store.hasLoadedOnce {
                    content
                } else {
                    loading.onAppear { store.refresh() }
                }
            }
        }
        .frame(width: 322)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.panelStroke(scheme), lineWidth: 0.75)
        )
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                if showSettings {
                    SettingsView(store: store, now: ctx.date) { showSettings = false }
                } else {
                    // Shared header + tabs; only the body below the switcher swaps.
                    PanelHeader(pill: headerPill(now: ctx.date))
                    PanelTabBar(selection: $tab)
                        .padding(.horizontal, 17).padding(.top, 12)
                    tabBody(now: ctx.date)
                }
                actionRow
            }
        }
    }

    /// The active tab's body — the mode-specific Overview panel, or the History chart.
    @ViewBuilder private func tabBody(now: Date) -> some View {
        switch tab {
        case .overview:
            switch store.snapshot.mode {
            case .subscription: SubscriptionPanel(store: store, now: now)
            case .burn:         BurnPanel(snapshot: store.snapshot, menuMetric: $store.menuMetric)
            }
        case .history:
            HistoryPanel(snapshot: store.snapshot, mode: store.snapshot.mode)
        }
    }

    /// The header badge, hoisted out of the panels so it's shared across tabs: a pulsing LIVE
    /// dot + CLAUDE MAX on a subscription (the dot means "this % is authoritative"), or the
    /// BEDROCK/API pill on pay-per-token.
    @ViewBuilder private func headerPill(now: Date) -> some View {
        switch store.snapshot.mode {
        case .subscription:
            HStack(spacing: 7) {
                if store.snapshot.quotaLeft(now: now)?.source == "live" {
                    HStack(spacing: 4) {
                        GlowDot(color: Theme.green, size: 5, glow: 3)
                        Text("LIVE").font(.system(size: 9, weight: .bold)).tracking(0.6)
                            .foregroundStyle(Theme.green)
                    }
                }
                Pill(text: "CLAUDE MAX", tint: Theme.green)
            }
        case .burn:
            Pill(text: store.snapshot.surface == .bedrock ? "BEDROCK" : "API", tint: Theme.amber)
        }
    }

    private var actionRow: some View {
        HStack {
            Text(store.hasLoadedOnce ? "updated \(updatedAgo(store.snapshot.lastUpdated)) · \(store.snapshot.fileCount) files"
                                     : "loading…")
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
            Spacer()
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 10, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(showSettings ? Theme.green : Theme.muted)
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 17).padding(.vertical, 9)
        .background(Theme.subtleFill)
    }

    private var loading: some View {
        TimelineView(.animation) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            VStack(spacing: 10) {
                BrandMark(size: 26, lineWidth: 3, fraction: 0.3, color: Theme.green)
                    .rotationEffect(.degrees(angle))
                Text("Reading ~/.claude…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 46)
        }
    }

    private func updatedAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 2 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }
}

/// First-run / stale-bookmark grant prompt (sandboxed builds).
struct GrantView: View {
    @ObservedObject var access: AccessManager
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(pill: Pill(text: "SETUP", tint: Theme.amber))
            VStack(spacing: 8) {
                BrandMark(size: 40, lineWidth: 4, fraction: 0.63, color: Theme.green)
                Text("Grant read access to ~/.claude")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Token Tab reads only token counts from the logs Claude Code already writes. No network, read-only, sandboxed.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            Button {
                access.requestAccess()
                if access.logDir != nil { store.accessChanged() }
            } label: {
                Text("Choose ~/.claude…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.green)
            .padding(.horizontal, 20)
            TrustFooter(text: "Local only — nothing leaves this Mac").padding(.bottom, 14)
        }
        .padding(.top, 2)
    }
}

extension Color {
    init(hex8: Int) {
        self.init(.sRGB,
                  red: Double((hex8 >> 16) & 0xFF) / 255,
                  green: Double((hex8 >> 8) & 0xFF) / 255,
                  blue: Double(hex8 & 0xFF) / 255)
    }
}
