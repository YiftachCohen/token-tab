# Changelog

Notable changes per release. Since the product's promise is its trust surface, every
entry calls out changes to it explicitly (entitlements, parsed fields, rate table,
network posture) — see the [trust model](README.md#trust-model).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
versioning: [SemVer](https://semver.org) (0.x — minor bumps may change behavior).

## [Unreleased]

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
  resume/replay and per-class rate-limit resets. Five OpenAI models are priced
  (`gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5.3-codex`); anything else
  stays honestly unpriced rather than costing $0.
- **Two-gauge Overview and a max-pressure menu bar.** The provider under the most 5-hour
  pressure headlines (Codex reads as `42% Cdx`); the other becomes a compact secondary
  row that swaps focus on tap, and is hidden when it has no usage. Only real percentages
  compete for the headline — Codex's official `used_percent`, Claude's only with a
  configured or live-calibrated cap — otherwise it falls back to combined today-tokens.
  A merged Claude+Codex percentage is deliberately never shown: it isn't a real number.
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
