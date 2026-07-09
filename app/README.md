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
  once there's a cap — learned automatically from a Live % reading, or set by hand
  (`TOKENTAB_WINDOW_CAP`) as a fallback; otherwise the runway is shown as exact time —
  never a guessed %. Settings (and the cap/Live % controls) only appear in this mode —
  there's a real server quota behind them.
- **Pay-per-token** (`us.anthropic.*` Bedrock / API) → **burn**: `$` spent today + tokens,
  a live burn rate, and the main-vs-sub-agent split. A segmented control picks what the
  menu bar shows ($ or tokens). No cap or Live % UI here — there's no server quota to
  fetch on pay-per-token, so the log-derived numbers are already the complete picture.

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
`swift run` builds only the bare `TokenTab` binary — there's no bundle, so no
`TokenTabLiveHelper` and no `Contents/Library/LaunchAgents` plist to register. The app
notices (`LiveHelperManager.status == .unavailable`) and falls back to showing the
`adapters/install-live.sh` / `node adapters/write-live.mjs` commands instead of a Live %
toggle that could never work.

**The real sandboxed app:**
```sh
cd app
./Scripts/build-app.sh        # builds + ad-hoc-signs "Token Tab.app" with entitlements
open "Token Tab.app"
```
On first launch the sandboxed app asks you to grant read access to `~/.claude` (a
one-time security-scoped bookmark; `~/.claude` is hidden, so the picker is opened with
hidden files shown). The grant is **read-only** and scoped — it can read nothing else and
write nothing anywhere. This build also has the bundled live helper, so **Turn on Live %**
in the dropdown or Settings works: one click registers
`Contents/Library/LaunchAgents/com.tokentab.liveagent.plist` via `SMAppService`, and
launchd runs `Contents/MacOS/TokenTabLiveHelper` on its own timer — see the root
[`README.md`](../README.md#live-server-) for the full story.

You can also open the package in Xcode (`File ▸ Open ▸ app/Package.swift`) and hit Run
(same as `swift run` — no bundled helper).

## App icon

<img src="Branding/gauge-appicon.png" alt="Token Tab app icon" width="96" align="right">

The icon is the **gauge** mark (the design's V1): a dark squircle with the live progress
ring. It's drawn vector-first with Core Graphics in [`Scripts/make-icon.swift`](Scripts/make-icon.swift),
so it stays crisp from 16px up — no external rasterizer needed. `Scripts/make-icon.sh`
packs the `.iconset` into `Bundle/AppIcon.icns` with `iconutil`.

`AppIcon.icns` is a **build artifact** (gitignored). `build-app.sh` copies it into the
bundle and regenerates it on demand if it's missing, and `Info.plist` points at it via
`CFBundleIconFile`. The shared vector sources and web assets (favicon, wordmark) live in
[`Branding/`](Branding/README.md), with the palette and regen commands.

## The two-minute audit (native build)

```sh
# App Sandbox ON, and NO network entitlement (prints sandbox + user-selected, no network):
codesign -d --entitlements :- "app/Token Tab.app"

# No network APIs anywhere in the sources (prints nothing):
grep -RnE "URLSession|Socket|NWConnection|CFSocket|getaddrinfo|https?://" app/Sources

# No subprocess in app/Sources (prints nothing) — the sandboxed app cannot shell out, and
# the one process that does (the live helper) is deliberately fenced OUTSIDE this tree:
grep -RnE "Process\(|posix_spawn|NSTask|popen|execv|/bin/" app/Sources

# It never reads your content: the only matches are two comments saying so. The JSONL
# decoder (LogReader.Line) has no `content` field, so no code path surfaces your prompts
# or code — only token-count metadata:
grep -RnE "message\.content|\"content\"" app/Sources
```

The live helper is the one deliberate exception to "no subprocess," and it's auditable on
its own terms — a ~200-line file (`app/Helper/main.swift`) outside `app/Sources`, and a
binary with the opposite signature from the app it ships next to:

```sh
# The app binary: sandbox ON, no network entitlement — same as above, unchanged by Live %:
codesign -d --entitlements :- "app/Token Tab.app"

# The helper binary: NO sandbox entitlement (prints nothing) — that's the point, it's the
# one process built to exec `claude` and make the network call:
codesign -d --entitlements :- "app/Token Tab.app/Contents/MacOS/TokenTabLiveHelper"

# It only ever runs `claude -p "/usage" --output-format json` — this prints exactly ONE
# line (the single Process() that execs claude); no network API matches at all:
grep -nE "Process\(|URLSession|Socket" app/Helper/main.swift
```

It's never spawned by the app — `launchd` runs it, and only after the user registers it
with `SMAppService` by clicking **Turn on Live %** (visible + revocable afterward in
System Settings ▸ Login Items). See the root [`README.md`](../README.md#live-server-)
for the full trust story.

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
  Sources/TokenTabCore/         Core.swift / Pricing.swift / Format.swift / LiveParse.swift — pure port of src/
  Sources/TokenTab/
    TokenTabApp.swift           @main MenuBarExtra agent (LSUIElement, no Dock icon)
    Model/                      LogReader, LiveReader, LiveHelperManager (SMAppService), Access (grant), UsageStore, Config, Probe, FolderWatcher
    Views/                      Theme, Components, MenuBarLabel, SubscriptionPanel, BurnPanel, HistoryPanel, DropdownView, LoadingView, SettingsView
  Helper/main.swift             TokenTabLiveHelper source (~200 lines) — NOT sandboxed,
                                 fenced outside Sources/ so the app/Sources audit stays
                                 clean. The ONE subprocess in the native stack: runs
                                 `claude -p "/usage" --output-format json`
  Bundle/                       Info.plist (CFBundleIconFile) + TokenTab.entitlements
                                 (sandbox, no network) + com.tokentab.liveagent.plist
                                 (the bundled LaunchAgent, label com.tokentab.liveagent)
  Branding/                     gauge logo sources (SVG) + generated favicons / wordmark / hero
  Scripts/build-app.sh          assemble + sign the .app: helper first (own identifier
                                 com.tokentab.TokenTabLiveHelper, no entitlements), then
                                 the app bundle (regenerates the icon if missing)
  Scripts/make-icon.swift       Core Graphics renderer for the gauge mark (iconset / favicon / hero)
  Scripts/make-icon.sh          → Bundle/AppIcon.icns   ·   make-branding.sh → web/README assets
  Tests/TokenTabCoreTests/      core + parity tests ported from ../test/core.test.mjs
  Tests/TokenTabAppTests/       I/O characterization tests (LogReader, RecordCache)
```

`build-app.sh` assembles the bundle's `Contents/`, which isn't checked in:
`Contents/MacOS/TokenTab` (the sandboxed app binary), `Contents/MacOS/TokenTabLiveHelper`
(the unsandboxed helper binary), and `Contents/Library/LaunchAgents/com.tokentab.liveagent.plist`
(copied straight from `Bundle/`).

## Status / not yet

- **Claude only** (reads `~/.claude`). The design's second agent, **Codex** (`~/.codex`),
  is designed-in (colors, the main/sub split) but its parser is not built yet — the
  subscription side-metric shows the Claude row only until it ships.
- **Distribution builds are a separate script.** `build-app.sh` ad-hoc-signs for local
  use. To hand the `.app` to someone else, `Scripts/package-app.sh` builds a universal
  binary, signs with a Developer ID (hardened runtime), notarizes, staples, and drops a
  checksummed zip in `dist/` — see [`RELEASING.md`](../RELEASING.md).
- **Refresh** is event-driven: an **FSEvents** watch on `~/.claude` re-reads only when the
  logs actually change (debounced), so updates are near-instant and idle CPU is ~0 (no
  polling). A 30s clock tick advances the runway display without touching disk, and a 90s
  safety refresh covers the rare case the stream can't start (e.g. an unusual sandbox).
