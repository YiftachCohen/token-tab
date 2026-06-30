# Token Tab

<p align="center">
  <img src="app/Branding/gauge-appicon.png" alt="Token Tab" width="116" height="116"><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="app/Branding/gauge-wordmark-dark.png">
    <img src="app/Branding/gauge-wordmark.png" alt="Token Tab" width="172">
  </picture>
</p>

[![CI](https://github.com/YiftachCohen/token-tab/actions/workflows/ci.yml/badge.svg)](https://github.com/YiftachCohen/token-tab/actions/workflows/ci.yml)

Token Tab shows your Claude Code token usage in the macOS menu bar. It reads the logs
Claude Code already writes to `~/.claude` — no API keys, no keychain, no network calls.
It reads token counts off disk and shows them; nothing leaves your machine.

Click the menu bar item for your current 5-hour usage window (with an exact reset
countdown) and a local cost estimate.

## What it reads

- `~/.claude/projects/**/*.jsonl` — the transcripts Claude Code already writes.
- Tokens per model, per surface (subscription / Bedrock), per window (today / this week / last 5h).
- A dollar **estimate** from a bundled per-model rate table — local arithmetic, not an invoice (see [Cost](#cost)).

Works the same whether Claude Code talks to the Anthropic API, a Max/Pro subscription,
or AWS Bedrock: the token counts are in the local logs either way, so no AWS
credentials are needed to read them.

## Trust model

The point of Token Tab is that it has no way to leak anything. Each claim is verifiable:

- **No network.** No network code, no dependencies.
- **No content.** The parser decodes only the metadata it needs — `type`, `model`,
  `message.id`, `requestId`, `usage`, `timestamp`, `isSidechain`. It never touches
  `message.content` (your prompts, code, and responses).
- **No state.** No cache, no telemetry, nothing written.

What it can't claim is to be *blind* to your data. Any usage meter has to read the
logs, and those logs contain your prompts. The narrower guarantee holds: it reads the
numbers, sends nothing, stores nothing.

### Audit it yourself

It's one dependency-free script. These greps over `src/` all print nothing:

```sh
grep -RnE "fetch|http|https|net\.|URLSession|Socket|dns" src/   # no network
grep -RnE "child_process|spawn|execFile" src/                   # no subprocess
grep -RnE "\.content" src/ | grep -v "//"                       # never reads content
cat package.json | grep -A1 dependencies                        # -> {}
```

The parser is `recordFromLine` in `src/core.mjs` — it returns `message.id`, `model`,
`usage`, `timestamp`, `isSidechain`, never content. The one subprocess in the repo is
the opt-in live reader, fenced outside `src/` in `adapters/` (see
[Live server %](#live-server--opt-in)). The native app's own audit — sandbox
entitlements, no-network greps over `app/Sources` — is in
[`app/README.md`](app/README.md#the-two-minute-audit-native-build).

## What runs where

One job — read the logs, aggregate, show usage — as two engines (a JS core and a Swift
port kept in parity) behind three front-ends. Only the opt-in live path touches the
network:

| Piece | What it is | Network? |
|---|---|---|
| `src/` JS engine | parse + dedup + aggregate | no |
| **CLI** | `node src/token-tab.mjs` → a terminal report | no |
| **SwiftBar** | shell wrappers run the JS engine on a timer | no¹ |
| **Native app** | `app/Token Tab.app`, the menu-bar UI (App-Sandboxed, no network entitlement) | no — kernel-enforced |
| **Live sidecar** | `adapters/write-live.mjs` runs `claude /usage`, writes a cache file | yes — via `claude` |

¹ only the `…-live.2m.sh` variant calls `claude`; the default `…30s.sh` does not.

## Quick start

### CLI
```sh
node src/token-tab.mjs            # human report
node src/token-tab.mjs --json     # machine-readable
node src/token-tab.mjs --swiftbar # SwiftBar format
```

### Menu bar — SwiftBar
One symlink and you have `◧ <tokens>` in the menu bar in about a minute. See
[`swiftbar/README.md`](swiftbar/README.md). SwiftBar may need Full Disk Access to read
`~/.claude` — broader than the native app's scoped grant; it's the fast on-ramp.

### Menu bar — native app
A SwiftUI `MenuBarExtra` app, App-Sandboxed with no network entitlement, reading
`~/.claude` through a scoped read-only grant. It runs locally today — build and run it
from [`app/README.md`](app/README.md). Not yet notarized for distribution.

## Accuracy

Validated against [`ccusage`](https://github.com/ryoppippi/ccusage) on real logs:
**99.997% match** on Claude token counts. Two notes:

- `ccusage` now also counts Codex (`gpt-5.5`); Token Tab is Claude-only, so compare
  Claude-only subtotals.
- Streaming emits several usage lines per message that share one id, with
  `output_tokens` growing across them; the parser keeps the last (final) line. It's the
  one dedup rule that moves the total, and a test pins it.

## Cost

The report and dropdown show a dollar **estimate** next to the token counts — today,
this week, all time, and per model. It's local arithmetic on a bundled rate table, on
by default (no network, no key). Scope:

- **An estimate, not your bill.** Bedrock region surcharges and cache-TTL nuances
  aren't modeled.
- **The rate table is [`src/pricing.mjs`](src/pricing.mjs)** — Anthropic's published
  USD-per-million list rates, there to audit and edit. Cache classes derive from the
  input rate by Anthropic's multipliers: cache **write** = 1.25× input (the 5-minute
  rate; logs don't record the TTL), cache **read** = 0.10× input. All four token
  classes are priced separately.
- **`[1m]` and Bedrock ids normalize to the base model** — no long-context premium on
  current models; `us.anthropic.<id>` reuses the same list rate.
- **Unknown model ⇒ tokens counted, price not invented.** It still counts toward every
  token total; it just lands in an `unpriced` line instead of getting a guessed dollar
  figure.

Token counts reconcile with `ccusage` (per-model within ~0.03%). The **dollar totals
differ by design** — `ccusage` prices off LiteLLM's community table, Token Tab off
Anthropic's list rates — so expect divergence on cache-heavy, Opus-tier usage. Token
Tab's rates sit in one short, editable file.

## Configuration

Set these as env vars, or in a local `KEY=VALUE` file kept out of the repo —
`~/.config/token-tab/env` (or `~/.token-tab.env`). Only `TOKENTAB_*` keys (plus
`CLAUDE_CODE_USE_BEDROCK`) are read; real env vars take precedence.

| Var | What it does |
|---|---|
| `TOKENTAB_LOG_DIR` | non-default log directory (default `~/.claude/projects`) |
| `CLAUDE_CONFIG_DIR` | reads `$CLAUDE_CONFIG_DIR/projects` |
| `TOKENTAB_WINDOW_CAP` | your plan's 5h token cap, to show a window `%` (see below) |
| `CLAUDE_CODE_USE_BEDROCK` | Claude Code's Bedrock flag; switches the app to the pay-per-token panel² |
| `TOKENTAB_LIVE` | opt in to the live server `%` via `claude -p "/usage"` (off by default) |
| `TOKENTAB_LIVE_CACHE` | where the live sidecar writes its JSON (default `<logDir>/.token-tab-live.json`) |
| `TOKENTAB_CLAUDE_BIN` | absolute path to `claude` when it isn't auto-resolved (SwiftBar's minimal PATH often needs this) |
| `TOKENTAB_LIVE_DEBUG` | prints why live data was unavailable to stderr (diagnostic only) |

² On Bedrock, Claude Code logs bare `claude-*` ids that are indistinguishable from a
subscription, so the mode can't be inferred from the logs — this flag is the signal. A
sandboxed app launched from Finder won't see your shell exports, so put it in the env
file above too.

## The 5-hour window

The headline is your token count for today. On a subscription the dropdown also shows
your current 5-hour rate-limit window, computed entirely from local logs (Anthropic
resets usage in fixed 5-hour blocks anchored to your first message of the block).

- **The reset countdown is exact** ("Resets in 3h36m"), verified against Claude's own
  `/usage`: the window starts at your first message, not the top of the hour.
- **A `%` shows only when you set `TOKENTAB_WINDOW_CAP`.** Anthropic doesn't publish the
  per-plan cap, and Token Tab won't guess one. To get it: open Claude's `/usage`, note
  "N% used", and set the cap to `current-window-tokens / (N/100)`. For example, 20M at
  5% ⇒ `TOKENTAB_WINDOW_CAP=400000000`.

## Live server % (opt-in)

The live server `%` (what Claude's `/usage` shows) is available with `TOKENTAB_LIVE=1`.
It does not make Token Tab phone home: it shells out to the official `claude` CLI
(`claude -p "/usage"`), which does the keychain read and the network call, and Token
Tab only parses the printed summary. The spawn lives in `adapters/claude-live.mjs`,
outside the audited `src/` core, so the `src/` audit stays clean even with live on.

- **Fails closed.** If `claude` can't be resolved, times out, or its output format
  changes, it falls back to the local estimate and shows a gray `live unavailable` line
  (set `TOKENTAB_LIVE_DEBUG=1` for the reason).
- **Native app: via a sidecar.** The sandboxed app can't spawn `claude`, so the opt-in
  writer `adapters/write-live.mjs` runs `/usage` in a separate, user-launched process and
  writes the parsed `%` to `<logDir>/.token-tab-live.json`; the app reads that file as
  plain data (inside the folder you already granted, ignored by both log walkers — hidden
  and not `*.jsonl`). The "no network" guarantee stays enforced — the network lives in the
  sidecar you scheduled.

  ```sh
  adapters/install-live.sh             # LaunchAgent, refreshes every 5 min
  adapters/install-live.sh uninstall   # stop + remove it
  node adapters/write-live.mjs         # one-off, no scheduler
  ```

  With a fresh reading the app headlines `91% left · live` and learns your cap from it
  (cap ≈ window tokens ÷ session `%`), persisting it so a real `%` keeps showing once the
  reading goes stale. On the menu bar, install `swiftbar/token-tab-live.2m.sh` (refreshes
  every 2 minutes, sets `TOKENTAB_LIVE=1`); the default `token-tab.30s.sh` never spawns
  anything.

The local 5-hour window stays the default everywhere and needs no opt-in.

## Develop

```sh
npm test     # node --test, golden-fixture suite for the parser core
```

`src/core.mjs` is a pure, I/O-free parser (so tests pin every edge case without a
filesystem); `src/pricing.mjs` is the pure price table + cost math, injected into the
parser so the rates stay testable; `src/token-tab.mjs` is the thin I/O shell. The Swift
port in `app/Sources/TokenTabCore` is kept in deliberate parity — see
[`AGENTS.md`](AGENTS.md).

Branding assets and usage live in [`app/Branding/`](app/Branding/README.md).
License: MIT.
