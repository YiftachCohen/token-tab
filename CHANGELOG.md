# Changelog

Notable changes per release. Since the product's promise is its trust surface, every
entry calls out changes to it explicitly (entitlements, parsed fields, rate table,
network posture) — see the [trust model](README.md#trust-model).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
versioning: [SemVer](https://semver.org) (0.x — minor bumps may change behavior).

## [Unreleased]

## [0.3.0] — 2026-08-01

### Added
- **Codex CLI usage, as a second provider.** Token Tab now also reads OpenAI Codex CLI
  rollout logs from `~/.codex/sessions` (and `archived_sessions/`), opt-in per provider
  in Settings ▸ Providers. **Trust-surface change: a second directory is read.** The
  sandboxed app asks for its own read-only grant of `~/.codex` — a separate scope, not a
  widening of the `~/.claude` one — and the new parser
  (`recordsFromCodexLines` in `src/codex.mjs`, mirrored by `CodexLogReader.swift`)
  dispatches on each line's `type` and decodes only `token_count` usage totals,
  `rate_limits`, the `turn_context` model, and the `session_meta` id; `response_item`
  (content) lines are skipped by type before any payload is decoded. Still no network,
  still nothing written. Cumulative token counts are diffed per session, with dedup for
  resume/replay and per-class rate-limit resets. Twelve OpenAI models are priced — the
  `gpt-5.6` Sol/Terra/Luna tier, `gpt-5.5`, the `gpt-5.4` family, and the `gpt-5.x-codex`
  line (rates verified 2026-07-31 against OpenAI's per-model docs, including the
  2026-07-30 Terra/Luna price cut). Ids with no published rate — a research preview, an
  internal Codex slug — stay honestly unpriced rather than costing $0.
- **Two-gauge Overview and a max-pressure menu bar.** The provider under the most 5-hour
  pressure headlines the Overview; the other becomes a compact secondary row that swaps
  focus on tap, and is hidden when it has no usage. Only real percentages compete for the
  headline — Codex's official `used_percent`, Claude's only with a configured or
  live-calibrated cap — otherwise it falls back to combined today-tokens.
  A merged Claude+Codex percentage is deliberately never shown: it isn't a real number.
- **The menu bar shows both providers.** When Claude and Codex both have usage, the bar
  carries a gauge + figure per provider — `◔ 42%  ◕ 92%`, Claude always first, so position
  identifies each one. A provider with usage but no real percentage gets a dot and its token
  count rather than a ring implying a percentage that doesn't exist. Settings ▸ Providers ▸
  **MENU BAR** switches back to the single max-pressure figure (which keeps its `Cdx`
  suffix, since one glyph can't say whose it is). A Claude-only menu bar is unchanged.

### Changed
- **The menu-bar item is now an `NSStatusItem` hosting the SwiftUI label**, replacing the
  `MenuBarExtra` scene. `MenuBarExtra` renders only one `Text` and one `Image` in its label,
  which silently truncated the two-provider label to the first pair — the same limitation
  that once made a custom SwiftUI `Shape` invisible there. The dropdown is unchanged: the
  same `DropdownView` in a `.transient` `NSPopover`, which is what `.menuBarExtraStyle(.window)`
  already was. **No trust-surface change** — AppKit windowing only, no new capability, and
  the app still reads nothing but the granted log directories.
- **Every menu-bar percentage now reads "% left", for both providers.** Codex's official
  reading is natively `used_percent`, and showing it raw left the glyph and the number
  disagreeing — a 92%-full ring beside the figure `8%`. Both rings already fill to
  runway-left, so the figures match them now: 8% of the Codex window spent reads `92%`.
  The dropdown still quotes Codex's native "% used" where there's room to label it. The
  SwiftBar plugin's `◧` label changed the same way, so the two front-ends can't report the
  same state differently on one Mac. No parsing or trust-surface change — display only.
- **Each provider's numbers are now scoped to that provider.** Adding Codex quietly made
  several Claude-labelled figures include Codex: the inferred 5-hour window summed both
  providers' tokens (a Codex-heavy hour could read as 100% of the Claude cap), the
  dominant-surface check let Codex volume flip Claude's panel into pay-per-token mode, and
  the menu bar's Claude cost was the combined total. The 5-hour block now takes Claude
  records only, mode is decided by Claude's own surfaces, and the aggregate carries
  per-provider dollar subtotals (`providers.<p>.cost`, mirrored in both engines) that the
  Claude-labelled figures read from. History likewise opens on the focused provider's
  filter instead of `All`. Combined totals are unchanged and still labelled as combined.
- **An expired Codex percentage is no longer treated as current.** Codex writes logs only
  while it runs, so the last `rate_limits` snapshot persists indefinitely; once its
  `resets_at` has passed, the recorded percentage describes a window that no longer
  exists. It now stops competing for the menu-bar headline, stops drawing a ring, and is
  labelled "last known" in the detail lines instead of "official" — in the app and in the
  SwiftBar plugin alike.

### Fixed
- **The `~/.codex` grant is held to the same floor as `~/.claude`.** The Codex folder
  picker refused nothing, so a single click while it sat at the home folder would have
  handed the app the whole home directory, and a previously saved over-broad bookmark was
  re-opened on launch without checking. Both now apply the same rejection and self-heal
  the Claude grant has, and the picker points at `~/.codex` unconditionally (a
  `fileExists` pre-check is always false inside the sandbox, which is what dropped it at
  the home folder in the first place). **Trust-surface fix**, no capability added.
- **Codex `response_item` lines are dropped before `JSON.parse`, not after.** The reader
  decoded every line and only then discarded the content-bearing ones — the text was never
  surfaced, but it was parsed and allocated, which is not what the trust contract says.
  Both engines now read the top-level `type` off the raw string and skip non-whitelisted
  lines undecoded. The no-content tests prove it by feeding in an *unparseable*
  `response_item`: it has to be skipped silently rather than counted as malformed.
- **Codex changes now update the bar immediately.** Only `~/.claude` had an FSEvents
  watcher, so Codex-only activity waited on the 90-second safety refresh — up to about two
  minutes. A second watcher on the Codex root starts and stops with the provider toggle.
- **File diagnostics count both providers.** The native footer and the CLI's `files` figure
  counted only Claude's logs, so a Codex-only run reported "0 files" underneath live Codex
  usage. Both now report the total, with the per-provider split kept alongside it
  (`filesByProvider` in `--json`).
- **Trust footers name only the directories actually read.** The native footer ignored
  `TOKENTAB_PROVIDERS` and the CLI assumed `~/.claude` was read whenever Codex was on, so a
  single-provider configuration could claim a directory the run never opened. Both now
  derive the wording from the resolved provider flags — and the native app honours
  `TOKENTAB_PROVIDERS` for Claude too, so the flag means the same thing in both front-ends.

### Trust surface
- **Changed: a second log directory is read.** `~/.codex/sessions` (and
  `archived_sessions/`) joins `~/.claude/projects`, opt-in per provider in Settings ▸
  Providers. In the sandboxed app it needs its own read-only grant of `~/.codex` — a
  separate security-scoped bookmark, not a widening of the `~/.claude` one — held to the
  same floor (the home folder and any ancestor are refused, and an over-broad bookmark
  saved earlier is dropped and re-prompted).
- **Changed: new parsed fields, in the new reader only.** Codex rollout lines are
  dispatched on their top-level `type` off the raw string; only `event_msg`
  (`token_count` usage totals and `rate_limits`), `turn_context` (`model`), and
  `session_meta` (`id`) are decoded. `response_item` lines — the content-bearing ones —
  are skipped *before* `JSON.parse`, so their payload is never decoded or allocated. The
  Claude parser's field list is unchanged, and `message.content` is still never touched by
  either.
- **Unchanged: entitlements.** `app/Bundle/TokenTab.entitlements` is byte-identical to
  0.2.0 — still `app-sandbox` + `files.user-selected.read-only`, still no network
  entitlement. The bundled live helper's entitlements are unchanged too, and it remains
  opt-in and `launchd`-only.
- **Unchanged: network posture.** No network and no subprocess in `src/` or `app/Sources`;
  nothing is written to either log directory. The new Codex reader adds no live path — its
  percentages come from `rate_limits` already in the logs, not from a call.
- **Rate table:** twelve OpenAI models priced (rates verified 2026-07-31), mirrored in both
  engines. Ids with no published rate stay unpriced rather than costing $0.

## [0.2.0] — 2026-07-29

### Added
- **Claude Opus 5 (`claude-opus-5`) added to the rate table** at its list price of
  $5 / 1M input and $25 / 1M output — the same rate as Opus 4.8, so no existing cost
  changes. The bare `opus` alias now resolves to it (it's the family's current model),
  and `claude-opus-5[1m]` shares the base rate as usual. Trust-surface change: one new
  priced model, mirrored in both engines; Opus 5 tokens were previously counted but
  reported as unpriced.
- **CI now checks value-level rate-table parity and design-token drift.** Two new
  scripts alongside the trust audit: `.github/scripts/rates-parity.mjs` (the JS and
  Swift price tables must carry identical numbers, aliases, and cache multipliers) and
  `.github/scripts/design-lint.sh` (no new raw color/font literals outside
  `Theme.swift`; pre-existing ones are baselined as migration TODOs). No trust-surface
  change — these only tighten enforcement of existing rules.
- **One-click Live %.** The `.app` now bundles a live-usage helper
  (`Contents/MacOS/TokenTabLiveHelper`, source fenced at `app/Helper/main.swift`) plus a
  LaunchAgent plist (`Contents/Library/LaunchAgents/com.tokentab.liveagent.plist`).
  Turning on "Live %" — one click, in the dropdown's live row or Settings — registers it
  via `SMAppService`; macOS lists it under System Settings ▸ Login Items ("Token Tab"),
  visible and removable, and may ask for approval first (the app deep-links there). No
  more cloning the repo, installing Node, or pasting a script into Terminal to get the
  real server `%`.
- **The 5-hour token cap is now learned automatically** from a live reading (cap ≈
  window tokens ÷ session `%`) once Live % is on. `TOKENTAB_WINDOW_CAP` is now a
  fallback, not a requirement.
- **Mode-aware settings.** The cap and Live % controls only appear in subscription mode;
  API/Bedrock (pay-per-token) users see no live UI at all, since there's no server quota
  behind it — the log-derived tokens and cost are already the complete picture.
- **Shared env-file parser** (`EnvFile.parse`, `TokenTabCore`) reads
  `~/.config/token-tab/env` / `~/.token-tab.env` the same way in the app, the helper, and
  the JS engine.
- Docs restructured around the app as the primary product: `README.md`'s quick start is
  now install-the-app-first, with the CLI and SwiftBar demoted to a clearly labeled
  "power users" section; `app/README.md` documents the helper's layout and its own
  audit.

### Trust surface
- Unchanged for the app binary: still App-Sandboxed, still no network entitlement.
- New: a second binary in the same bundle, `TokenTabLiveHelper`, also App-Sandboxed
  (macOS ≥14.2 requires it — a sandboxed app may only register sandboxed agents), with
  exactly two extra powers: `network.client` (the `claude /usage` call) and scoped
  `~/.claude` read-write (`app/Bundle/TokenTabLiveHelper.entitlements`). It is never
  spawned by the app — only `launchd`, and only once the user opts in. It's fenced
  outside `app/Sources`, so the existing `app/Sources` audit greps (no
  `Process(`/`posix_spawn`/etc.) still print nothing.
- The script live path (`adapters/install-live.sh`) is unchanged and still works — now
  repositioned as the live source for the CLI/SwiftBar front-ends and the from-source
  audit path for the bundled helper. It uses a distinct LaunchAgent label
  (`com.tokentab.live` vs. the bundled agent's `com.tokentab.liveagent`), so the two
  can't collide, though running both is redundant (each calls `claude /usage`
  independently).

## [0.1.1] — 2026-07-09

### Fixed
- **First-run grant flow could capture the whole home folder.** In the sandboxed app
  the folder picker silently opened at `~` (a `fileExists(~/.claude)` pre-check can
  never succeed inside the sandbox), so a single click on "Grant read access" granted
  `$HOME` — and the log walker then enumerated it, tripping macOS's Desktop /
  media-library consent prompts. Now: the picker always opens at `~/.claude`;
  selecting the home folder (or any ancestor) is refused with an explanation; and an
  over-broad bookmark saved by 0.1.0 is dropped and re-prompted on next launch
  (self-healing — affected installs recover on update).
- Relaunches now resolve the granted folder to its `projects` subdirectory the same
  way the first run does (the saved-bookmark path previously skipped that step).

### Trust surface
- Unchanged: entitlements and parsed fields are identical to 0.1.0. The fix narrows
  what the log walker can ever be pointed at.

## [0.1.0] — 2026-07-03

First tagged release.

### Added
- **Native menu-bar app** (`Token Tab.app`): SwiftUI `MenuBarExtra`, App-Sandboxed with
  **no network entitlement**, reading `~/.claude` through a one-time security-scoped
  read-only grant. Ships as a Developer ID-signed, notarized, universal
  (arm64 + x86_64) zip.
- **Two modes, decided by your plan**: subscription → 5-hour-window runway with exact
  reset countdown; pay-per-token (Bedrock/API) → $ today, burn rate, main/sub-agent
  split. `CLAUDE_CODE_USE_BEDROCK` / `TOKENTAB_MODE` override for sandboxed setups.
- **History tab**: daily bar chart (7/14/30-day), $ ⇄ tokens switch,
  vs-previous-period delta, busiest model.
- **CLI** (`node src/token-tab.mjs`; on npm as `@ycstudios/token-tab`, installed
  command `token-tab`): human, `--json`, and `--swiftbar` reports. Zero runtime
  dependencies.
- **SwiftBar plugin** (`swiftbar/token-tab.30s.sh`): the one-symlink on-ramp.
- **Cost estimates** from a bundled, auditable rate table (`src/pricing.mjs`,
  mirrored in Swift): Anthropic list rates, all four token classes, unknown models
  counted but never priced. Token counts validated against `ccusage` (99.997%).
- **Opt-in live server %** (`TOKENTAB_LIVE=1`): via the official `claude` CLI in a
  sidecar, fenced outside the audited core; fails closed.
- **CI-enforced trust invariants**: no network / no subprocess / never reads
  `message.content` / zero dependencies, greppable in two minutes; JS↔Swift engine
  parity pinned by shared golden fixtures.

### Trust surface
- Entitlements: `app-sandbox` + `files.user-selected.read-only` — nothing else.
- Parsed JSONL fields: `type`, `model`, `message.id`, `requestId`, `usage`,
  `timestamp`, `isSidechain`. `message.content` is never decoded.
