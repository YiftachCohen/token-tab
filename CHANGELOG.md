# Changelog

Notable changes per release. Since the product's promise is its trust surface, every
entry calls out changes to it explicitly (entitlements, parsed fields, rate table,
network posture) — see the [trust model](README.md#trust-model).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
versioning: [SemVer](https://semver.org) (0.x — minor bumps may change behavior).

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
