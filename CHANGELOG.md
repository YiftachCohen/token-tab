# Changelog

Notable changes per release. Since the product's promise is its trust surface, every
entry calls out changes to it explicitly (entitlements, parsed fields, rate table,
network posture) — see the [trust model](README.md#trust-model).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
versioning: [SemVer](https://semver.org) (0.x — minor bumps may change behavior).

## [Unreleased]

### Fixed
- **The live helper couldn't run `claude` at all, and said so in a way nobody could act on.**
  Claude Code ≥2.1 opens a uid-scoped lock dir at `/tmp/claude-<uid>` on startup; the helper's
  sandbox didn't reach `/tmp`, so every run died with `EPERM` before the `/usage` call — 340
  consecutive failures over 46 hours in the case that surfaced this. **Trust surface:** the
  helper's entitlements gain `/private/tmp` read-write (the app binary is untouched — still
  sandboxed, still no network entitlement). `/tmp` is world-writable, so this grants no reach
  the helper didn't already have as the user. Its stderr is also no longer sent to
  `/dev/null`: a failure now logs claude's own last lines instead of a bare `claude exited 1`,
  which is why this took two days to spot. The parse-miss line gains the output's *length*
  only — never a snippet, since `/usage` names your skills, plugins and MCP servers.
- **A learned 5-hour cap no longer outlives its evidence.** The cap is inferred as
  `windowTokens / sessionPct`, a token count over a model-weighted server percentage, and was
  persisted with no age — so once live stopped, a ratio learned on a cheaper model mix kept
  driving the hero indefinitely. Against an all-Opus window that meant `78% left` on screen
  against a true `42%`. The cap now records when it was learned and expires after 24 hours,
  falling back to the time countdown the ring already shows with no cap — labelled as the
  clock, not usage — while the stale-live row states the consequence outright. Manual and
  `TOKENTAB_WINDOW_CAP` caps are stated intent, not inference, and never expire; a cap
  persisted by an older build is granted one window from first launch rather than voided. New
  dated `DESIGN.md` row.

## [0.4.0] — 2026-08-15

### Added
- **Claude's weekly allowance now headlines when it's the binding limit.** A 97%-spent week
  could hide behind a reassuring 4%-spent session: the menu-bar figure, the health dot and the
  hero all read the 5-hour allowance only, so the bar showed a comfortable `96%` left while the
  week was nearly gone. Both engines now resolve one *binding* Claude quota — the session,
  unless weekly is at least 70% used **and** more used than the session; a lone weekly reading
  is authoritative on its own; a stale live reading still falls back to the local cap. Weekly
  figures carry a compact `wk` suffix so a percentage is never ambiguous about its period —
  including the SwiftBar `◧` label, which gains the suffix in the weekly-binding case only.
  The panel follows: weekly owns the hero with constraint copy instead of a token-runway
  projection it can't honestly compute, the non-binding session allowance survives as a compact
  secondary row, and the weekly detail cell is suppressed while weekly is the hero. Health
  thresholds moved into one `Health.forQuota`, so the same server percentage can't mean three
  different things across hero, mini-bar and ring. Codex's weekly window still stays out of
  cross-provider comparison — this supersedes the 5h-only headline rule for Claude only, as a
  dated `DESIGN.md` row.
- **A spinning brand mark while the first aggregate loads**, in place of a misleading `0.0M`
  reading in the menu bar. It's a vector-layer transform on `BrandMark` rather than a fresh
  `NSImage` per frame, so it stays smooth; it respects Reduce Motion and carries an
  accessibility label.

### Changed
- **The app's memory footprint is roughly halved** — 236 MB settled / 363 MB peak → **136 MB
  settled / 136 MB peak** against a ~4 GB log history (release build), with the per-refresh
  spikes gone entirely and cold start peaking near 200 MB. Only ~63 MB of that was ever live
  data; the rest was malloc high-water from transients: the cache flush encoded all of history
  as one boxed JSON tree, every FSEvents fire re-read the active session file in full, and each
  dedup pass minted ~100k fresh concatenated key strings. Now: byte-level incremental tail
  parsing over mapped file data with resumable offsets, a streamed `record-cache-v3.jsonl`
  store that flushes and hydrates one entry at a time, pair-enum dedup keys, and memoized
  per-model rate resolution in the Swift `Pricing` engine. **Numbers are unchanged** — `--probe`
  totals stay byte-identical to the JS CLI, and the existing parity fixtures are untouched.
  The superseded `record-cache-v1.json` / `-v2.json` stores are deleted on sight; the cache is
  disposable either way. Half-written trailing lines are counted transiently but never cached,
  so they can't poison a resume offset, and a persisted offset outside `[0, size]` is rejected
  on hydration (the store is user-editable by design).
- **The pitch says "verifiable" instead of "provably safe."** Nothing here is proven, and the
  opt-in live helper really does hold the network-client entitlement, so "provably safe" was an
  overclaim — and "safe" reads as a promise about outcomes rather than a statement about
  capabilities. The accurate, stronger claim is capability absence: it reads the local logs,
  nothing leaves your machine, and you can check both. Codex is lifted into the taglines too —
  this is a Claude Code + Codex meter now, with trust as the closer rather than the headline.
  The npm package description changed with it; no behavior or entitlement changed.
- **Product screenshots are rendered from the real views, never screenshotted.** A hand-captured
  image leaks project names through the author's `~/.claude`, pins whatever numbers that day
  produced, and can't be re-shot identically after a redesign. The shipping `DropdownView` is now
  staged in an offscreen window over a procedural wallpaper and captured from fixture data,
  behind `TOKENTAB_SHOTS=1` so CI and a plain `swift test` are unaffected. `DropdownView` gains
  an init with `initialTab`/`initialSettings`, defaulted to the shipped behavior and never passed
  by the app. Ships alongside a repo-local `qa-visual` skill for install-free visual QA.

### Fixed
- **Live % no longer nags on a five-minute loop after you bin an old copy of the app.** The
  LaunchAgent record names one specific bundle, not a bundle id, so deleting the copy that owns
  the registration leaves launchd pointed at the Trash — and macOS won't execute code from
  there. The helper is refused every `StartInterval`, and *"Token Tab" Not Opened* returns every
  five minutes with no button that can fix it, while `SMAppService` still reports `.enabled` so
  the in-app toggle looks healthy. Registering again re-points the record at the running copy,
  so launch now heals it — guarded on `.enabled` (it can never switch Live % back on for someone
  who turned it off in Login Items) and on a bundled agent plist (the `swift run` dev path is
  untouched). Not a signing problem: the binned bundle still passes `spctl`, `stapler` and
  `codesign --verify`; location is the whole cause. README gains an **Uninstalling** section —
  upgrading in place is unaffected, since the replaced bundle still exists somewhere runnable.
- **The burn rate is scoped to its own provider.** It summed the trailing hour across both, so
  a busy Codex hour read as Claude's pace and vice versa. Both engines now carry
  `providers.<p>.lastHour`, pinned by `test/fixtures/parity/last-hour-burn-rate.json`.
- **`thisWeek` no longer loses an hour in a zone that springs forward at midnight.** The local
  week start is re-derived at local midnight instead of by subtracting fixed days.
- **Both engines now cut JSONL on ASCII newlines only, by their own rule.** Foundation's
  Unicode line-breaking split records containing U+0085 / U+2028 / U+2029 into undecodable
  fragments, silently dropping tokens — fixed by a new shared `JSONLText` behind both Swift log
  readers and `EnvFile`. The CLI had borrowed the same rule from Node's `readline`, which as of
  **Node 24** breaks on U+2028/U+2029 too: on a current runtime the CLI silently dropped exactly
  the records the app had just been taught to keep (a turn quoting minified JS or exported JSON
  is the usual source). Both readers now stream through an explicit scan (`src/jsonl.mjs`, the
  JS twin of `JSONLText`), so the rule is stated in each engine rather than inherited from a
  runtime. CI's Node matrix now runs through the newest release instead of stopping at the
  current LTS, which is why this reached a tag at all.
- **The CLI's menu-bar percentage is rounded and clamped like the app's**, so one Mac can't get
  `◧ 35.900000000000006% Cdx` from one front-end and `36%` from the other.
- **Clicks land anywhere on the menu-bar label.** The custom SwiftUI label now ignores AppKit
  pointer hit-testing, so a click on the rings, figures or padding reaches the status button and
  closes an open popover, instead of being swallowed. Covered by a regression test across the
  full label width.
- Smaller app-side correctness fixes with tests, in `Probe`, `UsageStore`, `MenuBarLabel` and
  `HistoryPanel`; the README's "no state" claim is replaced by an accurate account of what the
  app caches locally.

### Trust surface
- **Unchanged: entitlements.** `app/Bundle/TokenTab.entitlements` is byte-identical to 0.3.3 —
  `app-sandbox` + `files.user-selected.read-only`, still no network entitlement. The bundled
  live helper's entitlements are unchanged too, and it remains opt-in and `launchd`-only; the
  new heal-on-launch call only asks launchd to re-schedule a job it already had.
- **Unchanged: parsed fields.** Same Claude and Codex field lists, and `message.content` is still
  never touched. The memory work changes how bytes are read, not which fields are decoded — and
  the cached type is still the same `UsageRecord`, which has no field for your text.
- **Unchanged: network posture.** No network and no subprocess in `src/` or `app/Sources`;
  nothing is written to either log directory.
- **Changed (local state only): the record cache is now `record-cache-v3.jsonl`** — plain JSONL,
  a version header then one entry per log file, still inside the app's sandbox container, still
  disposable. It holds file paths and numbers; the paths are Claude Code's project directory
  names, which encode the directories you work in. `README.md` documents the store in full.
- **Rate table unchanged:** 26 models and 3 aliases, mirrored across both engines.

## [0.3.3] — 2026-08-05

### Fixed
- **A weekly-only Codex reading is a percentage again in the menu bar.** 0.3.2 correctly
  re-keyed the Codex windows by duration, but the menu-bar label still read the 5h-only
  window while the dropdown's Codex panel and secondary row had moved to the displayed one.
  On any Mac whose Codex emits a weekly-only allowance — the current OpenAI shape — the bar
  fell through to a raw token count while the panel one click away showed a percentage for
  the same provider. Codex's own pair in the bar now shows whichever official window Codex
  published (5h when there is one, else weekly). The single max-pressure headline stays
  5h-only, so a weekly percentage still never competes with Claude's 5h percentage.
- **A menu-bar figure can no longer be truncated to `92…`.** The status item's width is what
  gives the hosted label its width, so a stale width didn't render as a narrow item — SwiftUI
  resolved the shortfall by truncating a figure, silently costing a number its percent sign.
  0.3.2 could sit at a one-pair width while rendering a two-pair label indefinitely, because
  the only trigger to re-measure was a store update, which fires before the label has actually
  changed. The re-measure is now driven by the label's own size changing, the width is measured
  from the label's ideal size rather than the width the item currently allows, and the label
  can no longer be compressed at all.
- **Codex's "as of" staleness caption gains day context**, matching the reset labels 0.3.2
  fixed: against a weekly window a reading can be days old and still describe the open window,
  so a bare "as of 21:15" read as fifteen minutes ago when it was Saturday.

**No trust-surface change** — same entitlements, same parsed fields, same read-only access,
no network. Display-only changes in the native app; the CLI and SwiftBar output is untouched.

## [0.3.2] — 2026-08-04

### Fixed
- **Weekly-only Codex rate limits no longer render as a false 5h gauge.** Codex can emit
  a weekly-only allowance in `rate_limits.primary`. Both engines now key
  `providers.codex.windows` off `window_minutes` (300 = 5h, 10080 = weekly) instead of the
  raw slot, so a weekly reading no longer masquerades as 5h pressure or competes with
  Claude's 5h percentage in the menu bar. Reset labels (CLI, SwiftBar, and the app) now
  gain day context when the reset isn't today, so a Saturday 18:19 weekly reset no longer
  reads as an already-passed 18:19 today. **No trust-surface change** — same fields parsed,
  same read-only access. Pinned by `test/fixtures/parity/codex-weekly-only-primary-slot.json`.

## [0.3.1] — 2026-08-02

### Fixed
- **The `~/.codex` grant was unreachable in the shipped app.** 0.3.0 decided whether Codex
  was present with `fileExists(~/.codex)` and gated the "Grant read access" button on the
  same check — but a sandboxed app cannot `stat` `~/.codex` without a scope, so the check is
  always false, folder there or not. Every sandboxed Codex user saw "~/.codex not found —
  nothing to read" with no way to grant, and the button that would have fixed it was hidden
  by the same false reading. Codex access now resolves through the three-way
  granted / direct-read / needs-grant state Claude already used: the button is offered from a
  state the sandbox can actually observe, the Settings row says "read access needed" instead
  of claiming the folder is missing, and the ingest path reads the directory the user granted
  rather than an assumed one. Granting `~/.codex/sessions` instead of `~/.codex` now also
  works (it climbs to the root the reader walks). **No capability added** — same read-only
  security-scoped bookmark, same entitlements.

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
