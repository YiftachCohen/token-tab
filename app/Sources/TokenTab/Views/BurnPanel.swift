// Token Tab — Mode B · Pay-per-token (Bedrock / Anthropic API).
//
// There's no limit to run out of, so the question flips to "what am I burning today?":
// dollars + tokens lead, with a live burn rate and the main-vs-sub-agent split. The
// menu-bar metric ($ or tokens) is chosen right here.

import SwiftUI
import TokenTabCore

struct BurnPanel: View {
    let snapshot: Snapshot
    @Binding var menuMetric: MenuMetric

    private var agg: Aggregate { snapshot.agg }
    private var split: MainSubSplit { agg.todaySplit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(pill: Pill(text: pillText, tint: Theme.amber))

            // HERO: today's burn
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "BURNED TODAY")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.usd(agg.cost?.today ?? 0))
                        .font(Theme.figure(40, weight: .bold))
                        .tracking(Theme.tightTracking(40))
                        .foregroundStyle(Theme.ink)
                    Text("est.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 6)
                Text("\(Fmt.grouped(agg.today)) ")
                    .font(Theme.mono(14)) +
                Text("tokens").font(Theme.mono(14)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 17).padding(.top, 16)

            // Menu-bar metric switch
            HStack(spacing: 10) {
                SectionLabel(text: "MENU BAR SHOWS")
                SegmentedToggle(selection: $menuMetric)
            }
            .padding(.horizontal, 17).padding(.top, 14)

            // Burn rate
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "BURN RATE")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.millions(agg.lastHourTokens)).font(Theme.figure(14))
                            .foregroundStyle(Theme.ink)
                        Text("tok/hr").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel(text: "≈ COST / HR")
                    Text(Fmt.usd(agg.cost?.lastHour ?? 0)).font(Theme.figure(14))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(12)
            .card()
            .padding(.horizontal, 17).padding(.top, 14)

            // Usage · main vs sub-agent
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel(text: "USAGE · MAIN vs SUB-AGENT")
                    Spacer()
                    HStack(spacing: 9) {
                        legend(color: Theme.green, text: "main")
                        legend(color: Theme.green.opacity(0.3), text: "sub")
                    }
                }
                MiniBar(fraction: mainFrac, subFraction: subFrac, color: Theme.green, height: 9)
                HStack {
                    Text("main \(Fmt.abbrev(split.mainTokens)) · \(Fmt.usd(split.mainCost))")
                    Spacer()
                    Text("sub-agent \(Fmt.abbrev(split.subTokens)) · \(Fmt.usd(split.subCost))")
                }
                .font(Theme.figure(11.5, weight: .regular))
                .foregroundStyle(Theme.muted)
                Text(modelsLine)
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 17).padding(.top, 16)

            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 12)
            HStack(spacing: 6) {
                GlowDot(color: Theme.green)
                Text("0 network calls · reads ~/.claude · bundled price table")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 17).padding(.vertical, 11)
        }
    }

    private var mainFrac: Double { split.total > 0 ? Double(split.mainTokens) / Double(split.total) : 0 }
    private var subFrac: Double { split.total > 0 ? Double(split.subTokens) / Double(split.total) : 0 }

    /// "BEDROCK" only when a deliberate signal said so — TOKENTAB_MODE=bedrock or the
    /// CLAUDE_CODE_USE_BEDROCK flag (both resolve to `surface == .bedrock`). Everything else
    /// pay-per-token is the generic "API": we don't claim a backend we can't prove from the
    /// logs (bare claude-* ids look identical).
    private var pillText: String {
        snapshot.surface == .bedrock ? "BEDROCK" : "API"
    }

    /// "Claude · Opus · Sonnet · Haiku" — the agent plus the model tiers actually present.
    private var modelsLine: String {
        let tiers = ["opus", "sonnet", "haiku", "fable"].filter { tier in
            agg.byModel.keys.contains { $0.lowercased().contains(tier) }
        }.map { $0.capitalized }
        return (["Claude"] + tiers).joined(separator: " · ")
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 5)
            Text(text).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
        }
    }
}
