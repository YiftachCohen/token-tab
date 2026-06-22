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
                    RoundedRectangle(cornerRadius: 5).fill(Color(hex8: 0x1C1D22))
                        .frame(width: 18, height: 18)
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                switch store.snapshot.mode {
                case .subscription:
                    SubscriptionPanel(snapshot: store.snapshot, now: ctx.date)
                case .burn:
                    BurnPanel(snapshot: store.snapshot, menuMetric: $store.menuMetric)
                }
                actionRow
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Text(store.hasLoadedOnce ? "updated \(updatedAgo(store.snapshot.lastUpdated)) · \(store.snapshot.fileCount) files"
                                     : "loading…")
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
            Spacer()
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
        VStack(spacing: 10) {
            BrandMark(size: 26, lineWidth: 3, fraction: 0.3, color: Theme.green)
                .rotationEffect(.degrees(0))
            Text("Reading ~/.claude…").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 46)
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
                if access.logDir != nil { store.refresh() }
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
