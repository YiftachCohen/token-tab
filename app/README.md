# Token Tab — native macOS menu-bar app

This is **Approach A**, the "keeper" from the design doc: a SwiftUI `MenuBarExtra` app
that reads `~/.claude/projects` locally and renders the two-mode dropdown from the
design. It makes **no network calls** — the shipped build is App-Sandboxed with **no
network entitlement**, so "cannot phone home" is a fact macOS enforces, not a claim.

The numbers come from a faithful Swift port of the audited JS engine (`../src/core.mjs`
+ `pricing.mjs`); their numbers reconcile **exactly** with `node ../src/token-tab.mjs --json`
on the same logs (verified on 1,262 real files — see "Reconcile" below).

## Two modes — decided by your plan, not a toggle

The headline auto-switches on the dominant surface detected from your model ids:

- **Subscription** (`claude-*` / Max·Pro) → **runway**: a ring + the exact time left in
  the rolling 5-hour window, with tokens demoted to a side metric. A token **%** appears
  only when you set a cap (`TOKENTAB_WINDOW_CAP`); otherwise the runway is shown as exact
  time — never a guessed %.
- **Pay-per-token** (`us.anthropic.*` Bedrock / API) → **burn**: `$` spent today + tokens,
  a live burn rate, and the main-vs-sub-agent split. A segmented control picks what the
  menu bar shows ($ or tokens).

The menu-bar glyph itself is the readability study's "Recommended" treatment: a
monochrome number (always legible on any wallpaper) plus one colored health dot.

## Overview & History

The dropdown has two tabs under a shared header:

- **Overview** — the mode-specific headline above (runway or burn).
- **History** — a daily bar chart with a `7 / 14 / 30-day` range and a `$ / tokens` switch.
  The period total, the **vs-previous-period** delta, the dashed daily-average line and the
  **busiest model** all re-shape together (Opus leads on `$`, Sonnet on tokens). The metric
  defaults to the mode's headline — tokens on a subscription, `$` on pay-per-token. It's
  sliced from a precomputed 60-day series (`dailyHistory`), so toggling re-reads nothing.

## Run it

**Fast dev path (unsandboxed, reads `~/.claude` directly):**
```sh
cd app
swift run            # menu-bar item appears immediately, live against your real logs
```

**The real sandboxed app:**
```sh
cd app
./Scripts/build-app.sh        # builds + ad-hoc-signs "Token Tab.app" with entitlements
open "Token Tab.app"
```
On first launch the sandboxed app asks you to grant read access to `~/.claude` (a
one-time security-scoped bookmark; `~/.claude` is hidden, so the picker is opened with
hidden files shown). The grant is **read-only** and scoped — it can read nothing else and
write nothing anywhere.

You can also open the package in Xcode (`File ▸ Open ▸ app/Package.swift`) and hit Run.

## App icon

<img src="Branding/gauge-appicon.png" alt="Token Tab app icon" width="96" align="right">

The icon is the **gauge** mark (the design's V1): a dark squircle with the live progress
ring. It's drawn vector-first with Core Graphics in [`Scripts/make-icon.swift`](Scripts/make-icon.swift),
so it stays crisp from 16px up — no external rasterizer needed. `Scripts/make-icon.sh`
packs the `.iconset` into `Bundle/AppIcon.icns` with `iconutil`.

`AppIcon.icns` is a **build artifact** (gitignored). `build-app.sh` copies it into the
bundle and regenerates it on demand if it's missing, and `Info.plist` points at it via
`CFBundleIconFile`. The shared vector sources and web assets (favicon, wordmark) live in
[`Branding/`](Branding) — see the repo README's *Branding* section.

## The two-minute audit (native build)

```sh
# App Sandbox ON, and NO network entitlement (prints sandbox + user-selected, no network):
codesign -d --entitlements :- "app/Token Tab.app"

# No network APIs anywhere in the sources (prints nothing):
grep -RnE "URLSession|Socket|NWConnection|CFSocket|getaddrinfo|https?://" app/Sources

# No subprocess (prints nothing) — the sandboxed app cannot shell out:
grep -RnE "Process\(|posix_spawn|NSTask|popen|execv|/bin/" app/Sources

# It never reads your content: the only matches are two comments saying so. The JSONL
# decoder (LogReader.Line) has no `content` field, so no code path surfaces your prompts
# or code — only token-count metadata:
grep -RnE "message\.content|\"content\"" app/Sources
```

## Reconcile against the audited JS engine

`--probe` runs the exact same read + aggregate the menu bar uses and prints the totals as
JSON, then exits (no UI). Run the bare binary (unsandboxed) so it reads the default dir:

```sh
swift build
.build/debug/TokenTab --probe          # native engine totals
node ../src/token-tab.mjs --json        # JS engine totals — fields match
```

## Layout

```
app/
  Package.swift                 SwiftPM: TokenTabCore (pure) + TokenTab (GUI) + tests
  Sources/TokenTabCore/         Core.swift / Pricing.swift / Format.swift — pure port of src/
  Sources/TokenTab/
    TokenTabApp.swift           @main MenuBarExtra agent (LSUIElement, no Dock icon)
    Model/                      LogReader, LiveReader, Access (grant), UsageStore, Config, Probe, FolderWatcher
    Views/                      Theme, Components, MenuBarLabel, SubscriptionPanel, BurnPanel, HistoryPanel, DropdownView, LoadingView, SettingsView
  Bundle/                       Info.plist (CFBundleIconFile) + TokenTab.entitlements (sandbox, no network)
  Branding/                     gauge logo sources (SVG) + generated favicons / wordmark / hero
  Scripts/build-app.sh          assemble + ad-hoc-sign the .app (regenerates the icon if missing)
  Scripts/make-icon.swift       Core Graphics renderer for the gauge mark (iconset / favicon / hero)
  Scripts/make-icon.sh          → Bundle/AppIcon.icns   ·   make-branding.sh → web/README assets
  Tests/TokenTabCoreTests/      core + parity tests ported from ../test/core.test.mjs
  Tests/TokenTabAppTests/       I/O characterization tests (LogReader, RecordCache)
```

## Status / not yet

- **Claude only** (reads `~/.claude`). The design's second agent, **Codex** (`~/.codex`),
  is designed-in (colors, the main/sub split) but its parser is not built yet — the
  subscription side-metric shows the Claude row only until it ships.
- **Notarization is deferred.** The build is ad-hoc-signed for local use; a Developer ID
  + notary round-trip is the step before handing the `.app` to someone else.
- **Refresh** is event-driven: an **FSEvents** watch on `~/.claude` re-reads only when the
  logs actually change (debounced), so updates are near-instant and idle CPU is ~0 (no
  polling). A 30s clock tick advances the runway display without touching disk, and a 90s
  safety refresh covers the rare case the stream can't start (e.g. an unusual sandbox).
