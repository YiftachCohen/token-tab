# Changelog

All notable changes to Token Tab are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-07-03

First tagged release — everything to date.

### Added
- **JS engine** (`src/core.mjs`): pure, I/O-free parser for
  `~/.claude/projects/**/*.jsonl` — streaming-aware dedup (last usage line per
  message id wins), per-model / per-surface / per-window aggregation, and the
  local 5-hour rate-limit window with exact reset countdown.
- **Pricing** (`src/pricing.mjs`): bundled Anthropic list-rate table with all
  four token classes priced separately; `[1m]` and Bedrock ids normalize to the
  base model; unknown models count tokens but land in an `unpriced` line.
- **CLI**: `node src/token-tab.mjs` with `--json` and `--swiftbar` output.
- **SwiftBar plugins** (`swiftbar/`): 30-second local meter, plus an opt-in
  2-minute live variant.
- **Native app** (`app/`): SwiftUI `MenuBarExtra`, App-Sandboxed with no
  network entitlement, with a Swift port of the engine
  (`app/Sources/TokenTabCore`) kept in fixture-verified parity with the JS
  core.
- **Live server %** (opt-in, `TOKENTAB_LIVE=1`): parses `claude -p "/usage"`
  via the fenced `adapters/` sidecar; fails closed to the local estimate.
- **Trust invariants in CI**: the audit job fails the build on any network,
  subprocess, content-read, or runtime-dependency regression; test matrix runs
  under UTC, Pacific/Auckland, and America/Los_Angeles.

### Accuracy
- Token counts validated against `ccusage` on real logs: 99.997% match on
  Claude-only totals (per-model within ~0.03%).

[Unreleased]: https://github.com/YiftachCohen/token-tab/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/YiftachCohen/token-tab/releases/tag/v0.1.0
