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
    var now: Date

    private var agg: Aggregate { snapshot.agg }

    /// The "easy" line: project the day's spend from today-so-far plus the last hour's rate
    /// run to local midnight. Shown only while actually burning (a live-ish rate), so it never
    /// invents a forecast from a cold meter.
    private var pacePrediction: String? {
        guard let cost = agg.cost, cost.lastHour > 0 else { return nil }
        let cal = Calendar.current
        let dayEnd = cal.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let hoursLeft = max(0, dayEnd.timeIntervalSince(now) / 3600)
        let projected = cost.today + cost.lastHour * hoursLeft
        return "On pace for ~\(Fmt.usd(projected)) today"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // HERO: today's burn
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "BURNED TODAY")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AnimatedNumber(target: agg.cost?.today ?? 0,
                                   font: Theme.hero(40, weight: .bold),
                                   tracking: Theme.tightTracking(40),
                                   color: Theme.ink) { Fmt.usd($0) }
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

            // Today · by model — on pay-per-token, "which model cost me money?" is the real
            // question (main-vs-sub-agent says nothing about spend). Sorted by $, with a
            // cost-share bar and a per-row %; deeper amber = more spend.
            byModelToday
                .padding(.horizontal, 17).padding(.top, 16)

            if let pace = pacePrediction {
                Text(pace)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(Theme.amber.opacity(0.16), in: Capsule())
                    .padding(.horizontal, 17).padding(.top, 14)
            }

        }
        .padding(.bottom, 12)
    }

    // MARK: today · by model

    private struct ModelSpend: Identifiable {
        let id = UUID(); let name: String; let tokens: Int; let cost: Double
    }

    /// Today's spend per model, from the History series' last (today) bucket, sorted by $
    /// (ties by tokens). The hero is "BURNED TODAY", so this breakdown is today too — and it
    /// reuses the already-computed per-day model maps, so Core stays untouched.
    private var todayByModel: [ModelSpend] {
        guard let today = snapshot.history.last else { return [] }
        var keys = Set(today.costByModel.keys); keys.formUnion(today.tokensByModel.keys)
        return keys.map { k in
            ModelSpend(name: prettyModel(k),
                       tokens: today.tokensByModel[k] ?? 0,
                       cost: today.costByModel[k] ?? 0)
        }
        .filter { $0.tokens > 0 || $0.cost > 0 }
        .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.tokens > $1.tokens }
    }

    /// Real model id → display name, folding the parser's placeholder ids (`<synthetic>` /
    /// `<unknown>` / empty) into a clean "Other" so they never render raw in the receipt.
    private func prettyModel(_ base: String) -> String {
        let id = base.lowercased()
        if base.isEmpty || id == "<synthetic>" || id == "<unknown>" { return "Other" }
        return Fmt.modelName(base)
    }

    /// Deeper amber = more spend (cost-rank tint, used by both the bar and the row dots).
    private func amberTint(_ rank: Int) -> Color {
        switch rank {
        case 0:  return Theme.amber
        case 1:  return Theme.amber.opacity(0.6)
        case 2:  return Theme.amber.opacity(0.38)
        default: return Theme.amber.opacity(0.24)
        }
    }

    @ViewBuilder private var byModelToday: some View {
        let rows = Array(todayByModel.prefix(4))
        // Share is of ALL of today's spend, so top-4 shares stay honest when more models exist.
        let total = todayByModel.reduce(0) { $0 + $1.cost }
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "TODAY · BY MODEL")
            if rows.isEmpty {
                Text("No spend yet today")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            } else {
                // Cost-share bar over a track; the track remainder reads as "everything else".
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.track)
                        HStack(spacing: 1.5) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                let share = costShare(r.cost, total: total)
                                RoundedRectangle(cornerRadius: 3).fill(amberTint(i))
                                    .frame(width: share > 0 ? max(2, CGFloat(share) * geo.size.width) : 0)
                            }
                        }
                    }
                }
                .frame(height: 8)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    let share = costShare(r.cost, total: total)
                    HStack(spacing: 9) {
                        Circle().fill(amberTint(i)).frame(width: 7, height: 7)
                        Text(r.name).font(.system(size: 12)).foregroundStyle(Theme.ink)
                        Text("· \(Fmt.abbrev(r.tokens))")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        Spacer(minLength: 8)
                        Text("\(Int((share * 100).rounded()))%")
                            .font(Theme.figure(11, weight: .regular)).foregroundStyle(Theme.faint)
                            .frame(width: 32, alignment: .trailing)
                        Text(Fmt.usd(r.cost))
                            .font(Theme.figure(12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func costShare(_ cost: Double, total: Double) -> Double {
        total > 0 ? cost / total : 0
    }
}
