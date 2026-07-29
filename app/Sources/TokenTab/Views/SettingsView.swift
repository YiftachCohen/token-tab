// Token Tab — Settings, reachable from every mode.
//
// The 5-hour cap and the live-% setup are otherwise only in the subscription panel. Once the
// app can land in the burn/API/Bedrock panel (which has no quota gauge), both controls would
// be unreachable — so this gives them a mode-independent home, opened from the gear in the
// shared action row. Same persistence as the inline editors: cap → UserDefaults (capOverride),
// live → the install command the sandboxed app can't run itself.

import SwiftUI
import AppKit
import TokenTabCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var access: AccessManager
    var now: Date
    var onClose: () -> Void

    @State private var capText = ""
    @FocusState private var capFocused: Bool

    private var snapshot: Snapshot { store.snapshot }

    /// Bridges the segmented Picker (needs a `Hashable` tag) to the store's `Surface?`.
    /// "auto" ⇄ nil; otherwise the Surface rawValue. Only Auto/Subscription/Bedrock are
    /// offered — `.untracked` isn't a useful user choice.
    private var modeSelection: Binding<String> {
        Binding(
            get: { store.surfaceModeOverride?.rawValue ?? "auto" },
            set: { store.surfaceModeOverride = ($0 == "auto") ? nil : Surface(rawValue: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(pill:
                Button(action: onClose) {
                    Text("Done").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            )

            // DISPLAY MODE — the sandbox-clean override (UserDefaults), the only one a
            // Finder-launched, App-Sandboxed app can actually reach (env vars and the dotfile can't).
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "DISPLAY MODE")
                Text("On Bedrock, Claude Code logs look like a subscription. Pick Bedrock / API to force the pay-per-token view.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                modePicker
            }
            .padding(.horizontal, 17).padding(.top, 14)

            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)

            // PROVIDERS — which coding tools' local logs Token Tab reads. Claude is the app's
            // foundation (its ~/.claude grant IS the app), so it's always on; Codex is opt-in
            // and needs its own read-only grant of ~/.codex (same mechanism, not a wider scope).
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "PROVIDERS")
                providerRow(name: "Claude", accent: Theme.green, on: .constant(true), locked: true,
                            detail: "~/.claude · always on")
                providerRow(name: "Codex", accent: Theme.indigo, on: $store.codexEnabled, locked: false,
                            detail: codexDetail)
                if store.codexEnabled, store.codexDirExists, !access.codexGranted {
                    // ~/.codex exists but the sandbox has no scope yet → offer the grant (mirrors
                    // the first-run ~/.claude grant). Unsandboxed dev reads it directly (no grant).
                    Button {
                        if access.requestCodexAccess() { store.accessChanged() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 11))
                            Text("Grant read access to ~/.codex").font(.system(size: 11, weight: .semibold))
                            Spacer(minLength: 6)
                        }
                        .foregroundStyle(Theme.indigo).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 17).padding(.top, 14)

            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)

            // 5-HOUR TOKEN CAP — works in any mode; the subscription gauge reads it for a real %.
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "5-HOUR TOKEN CAP")
                Text("Your plan's 5-hour token limit. Setting it turns the runway into a real “% left”.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("tokens, e.g. 400000000", text: $capText)
                        .textFieldStyle(.plain).font(Theme.figure(11))
                        .focused($capFocused)
                        .frame(maxWidth: .infinity)
                        .tokenFieldChrome(focused: capFocused)
                        .onSubmit(commitCap)
                    Button("Save", action: commitCap)
                        .buttonStyle(.borderedProminent).tint(Theme.green)
                        .font(.system(size: 11, weight: .semibold))
                    Button("Clear") { store.capOverride = 0; capText = "" }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(capStatus).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17).padding(.top, 14)

            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)

            // LIVE SERVER % — the same hand-off the subscription panel offers, just always reachable.
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: "LIVE SERVER %")
                    Spacer()
                    liveBadge
                }
                Text("The authoritative % from `claude /usage`. The app is sandboxed (no network), so a tiny helper fetches it and the app reads the cache. One-time setup — installs a background agent that refreshes every ~5 min:")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                commandChip(display: "adapters/install-live.sh", copy: installCopy, note: "auto-refresh")
                commandChip(display: "node adapters/write-live.mjs", copy: nodeCopy, note: "once")
                Text(adaptersDir == nil
                     ? "Run from the Token Tab folder. See README › Turn on live."
                     : "Copy → paste in Terminal once; it keeps running in the background. Stop it with `install-live.sh uninstall`.")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17).padding(.top, 14)

            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
            TrustFooter(text: "Local only — nothing leaves this Mac")
                .padding(.horizontal, 17).padding(.vertical, 12)
        }
        .onAppear { capText = store.capOverride > 0 ? String(store.capOverride) : "" }
    }

    /// The active cap and where it came from, by the same precedence the aggregator uses
    /// (manual override > live-calibrated > env/dotfile).
    private var capStatus: String {
        let eff = store.effectiveCap
        guard eff > 0 else { return "No cap set — the gauge shows the time countdown, not a %." }
        let src: String
        if store.capOverride > 0 { src = "manual" }
        else if store.calibratedCap > 0 { src = "learned from a live reading" }
        else { src = "from env/dotfile" }
        return "Active cap: \(Fmt.abbrev(eff)) tokens · \(src)."
    }

    @ViewBuilder private var liveBadge: some View {
        if let l = snapshot.live, l.isFresh(now: now) {
            HStack(spacing: 4) {
                GlowDot(color: Theme.green, size: 5, glow: 3)
                Text("on · fresh").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.green)
            }
        } else if snapshot.live != nil {
            Text("stale").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.amber)
        } else {
            Text("off").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.faint)
        }
    }

    /// On-brand 3-way segmented control (green selection on a subtle track) matching the app's
    /// SegmentedToggle — replaces the stock `.segmented` Picker, whose system-blue chrome was the
    /// one element breaking the panel's dark/green/glass look.
    private var modePicker: some View {
        HStack(spacing: 2) {
            modeSeg("Auto", "auto")
            modeSeg("Subscription", Surface.subscription.rawValue)
            modeSeg("Bedrock / API", Surface.bedrock.rawValue)
        }
        .padding(2)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func modeSeg(_ title: String, _ tag: String) -> some View {
        let on = modeSelection.wrappedValue == tag
        return Text(title)
            .font(.system(size: 11, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.onAccent : Theme.muted)
            .lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(on ? Theme.green : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: on ? Theme.green.opacity(0.3) : .clear, radius: 4, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { modeSelection.wrappedValue = tag }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func commitCap() {
        store.capOverride = Int(capText.filter(\.isNumber)) ?? 0
    }

    /// One provider row: an accent dot, the name, a one-line status, and a toggle (locked
    /// on for Claude — the app's core grant). A green-tinted Switch matches the panel.
    private func providerRow(name: String, accent: Color, on: Binding<Bool>, locked: Bool, detail: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).tint(accent)
                .disabled(locked)
                .accessibilityLabel("\(name) provider")
        }
    }

    /// Codex's one-line status under the toggle: whether logs exist and are readable.
    private var codexDetail: String {
        if !store.codexDirExists { return "~/.codex not found — nothing to read" }
        if store.codexEnabled && access.codexGranted { return "~/.codex · granted" }
        if store.codexEnabled { return "~/.codex · read access needed" }
        return "~/.codex · disabled"
    }

    // Absolute, cwd-independent install commands when we can locate the repo's adapters/ dir
    // (mirrors SubscriptionPanel) — so the copied command runs from any directory.
    private var adaptersDir: URL? { Config.adaptersDir() }
    private var installCopy: String {
        adaptersDir.map { shellQuoted($0.appendingPathComponent("install-live.sh")) } ?? "adapters/install-live.sh"
    }
    private var nodeCopy: String {
        adaptersDir.map { "node " + shellQuoted($0.appendingPathComponent("write-live.mjs")) } ?? "node adapters/write-live.mjs"
    }
    private func shellQuoted(_ url: URL) -> String { "'" + url.path + "'" }

    private func commandChip(display: String, copy: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(display).font(Theme.mono(10)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
                .padding(.vertical, 4).padding(.horizontal, 7)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.green)
            Text(note).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
    }
}
