# Token Tab

Token Tab shows your Claude Code token usage in the macOS menu bar, with your current
5-hour rate-limit window (exact reset countdown) a click away in the dropdown. It reads
the session logs Claude Code already writes on disk, so it needs no API keys, no
keychain access, and no AWS credentials, and it makes no network calls.

It reads only the usage numbers. Your prompts and code never leave your machine,
because the app has no way to send them anywhere.

> Status: early. The CLI + SwiftBar plugin work today and reconcile with `ccusage` to
> within 0.003%. The native sandboxed menu-bar app is the roadmap (see below).

## What it does

- Reads `~/.claude/projects/**/*.jsonl` (the transcripts Claude Code already writes).
- Counts tokens per model, per surface (subscription / Bedrock), and per time window
  (today / this week / last 5h).
- Works the same whether Claude Code talks to the Anthropic API, a subscription
  (Max/Pro), or **AWS Bedrock**. The token counts are in the local logs either way,
  so no AWS credentials are needed to read them.

## The trust model (the whole point)

Honest claims, each verifiable:

- **It cannot phone home.** No network code, no dependencies. (The native app will make
  this OS-enforced via App Sandbox with no network entitlement.)
- **It never reads your content.** The parser decodes only the metadata it needs:
  `type`, `model`, `message.id`, `requestId`, `usage`, `timestamp`, `isSidechain`. It
  never touches `message.content` (your prompts, code, and responses).
- **It keeps nothing.** No cache, no telemetry, no files written.

What it cannot promise: to be *blind* to sensitive data. Any usage meter must read the
logs, and those logs contain your prompts and code. The guarantee is narrower and
stronger: it reads the numbers, sends nothing, stores nothing.

### The two-minute audit

This is a single dependency-free script. Verify it yourself:

```sh
# 1. No dependencies to vet:
cat package.json | grep -A1 dependencies          # -> {}

# 2. No network, ever (prints nothing):
grep -RnE "fetch|http|https|net\.|URLSession|Socket|dns" src/

# 2b. No subprocess in the audited core (prints nothing). The opt-in live
#     adapter is fenced under adapters/, NOT in src/, so the core stays a clean
#     sweep even with live enabled:
grep -RnE "child_process|spawn|execFile" src/

# 3. It never reads content. The only `.content` mention is a comment, not code
#    (prints nothing):
grep -RnE "\.content" src/ | grep -v "//"

# 4. Confirm the parser reads only metadata: see `recordFromLine` in src/core.mjs
#    It returns message.id, model, usage, timestamp, isSidechain. Never content.

# 5. Read the whole thing. The audited core (core.mjs + token-tab.mjs +
#    live-parse.mjs) is pure parsing and rendering. The ONLY subprocess in the
#    repo is adapters/claude-live.mjs (the opt-in live path), audited separately:
grep -RnE "child_process|spawn|execFile" adapters/   # -> only adapters/claude-live.mjs
```

(When the native `.app` ships, the audit adds `codesign -d --entitlements :- TokenTab.app`
to show no network/keychain entitlement, plus `nettop -p <pid>` showing zero connections.)

## Quick start

### CLI
```sh
node src/token-tab.mjs            # human report
node src/token-tab.mjs --json     # machine-readable
node src/token-tab.mjs --swiftbar # SwiftBar format
```

### Menu bar (SwiftBar)
See [`swiftbar/README.md`](swiftbar/README.md). One symlink and you have `◧ <tokens>`
in the menu bar in about a minute. Note: the SwiftBar path may need Full Disk Access (a
broader grant than the native app will ask for); it's the fast on-ramp, not the keeper.

## Accuracy

Validated against [`ccusage`](https://github.com/ryoppippi/ccusage) on real logs:
**99.997% match** on Claude usage. Two things to know:

- `ccusage` now also counts **Codex** (`gpt-5.5`); Token Tab is Claude-only, so compare
  Claude-only subtotals.
- Streaming emits several usage lines per message that share an id; `output_tokens`
  grows across them, so the parser keeps the **last** (final, complete) line. This is
  the one dedup rule that affects the total, and it's pinned by a test.

## Configuration

- `TOKENTAB_LOG_DIR`: point at a non-default log directory.
- `CLAUDE_CONFIG_DIR`: respected (reads `$CLAUDE_CONFIG_DIR/projects`).
- `TOKENTAB_WINDOW_CAP`: your plan's 5h token cap, to show a window `%`. If unset, only
  the exact reset countdown shows (no guessed `%`). Derive it from Claude's `/usage`
  (see below).
- `TOKENTAB_LIVE`: opt in to the authoritative live server `%` via `claude -p "/usage"`
  (`1`/`true`/`yes`/`on`; canonical `=1`). Off by default. See "The live server %" below.
- `TOKENTAB_CLAUDE_BIN`: absolute path to the `claude` binary, when it isn't auto-resolved
  (SwiftBar's minimal PATH usually needs this).
- `TOKENTAB_LIVE_DEBUG`: when set, prints the reason live data was unavailable to stderr
  (diagnostic only; never stored).
- Set any of these as env vars, **or** in a local `KEY=VALUE` file kept out of the repo:
  `~/.config/token-tab/env` (or `~/.token-tab.env`). Only `TOKENTAB_*` keys are read;
  real env vars take precedence. This is where your cap lives so it never gets committed.
- Default log dir: `~/.claude/projects`.

## The usage window (subscription)

The menu-bar headline is your token count (today). On a Claude subscription, the
dropdown also shows your **current 5-hour rate-limit window**, computed entirely from
local logs. Anthropic resets usage in fixed 5-hour blocks anchored to your first message
of the block.

- **The reset countdown is exact** ("Resets in 3h36m"). Verified against Claude's own
  `/usage`: the window starts at your first message (not the top of the hour) and resets
  5 hours later.
- **A `%` shows only when you set `TOKENTAB_WINDOW_CAP`.** Anthropic doesn't publish the
  per-plan cap, and Token Tab will not invent one: a guessed `%` that disagrees with
  Claude is worse than none. To get an accurate `%`, open Claude's `/usage`, note "N%
  used", and set the cap to `current-window-tokens / (N/100)`. For example, 20M at 5% ⇒
  `TOKENTAB_WINDOW_CAP=400000000`.

## The live server % (opt-in)

The **live** server-`%` (what Claude's `/usage` and CodexBar show) is available as an
**opt-in** with `TOKENTAB_LIVE=1`. It does **not** make Token Tab phone home: it shells
out to the official `claude` CLI (`claude -p "/usage"`), which does the keychain read and
the network call, and Token Tab only parses the printed summary (zero token cost,
`num_turns: 0`). The spawn lives in `adapters/claude-live.mjs`, **outside** the audited
`src/` core, so the two-minute audit of `src/` still finds no network and no subprocess
(`grep -RnE "child_process|spawn|execFile" src/` prints nothing) even with live enabled.

- The trust boundary shifts honestly: Token Tab still opens no socket and reads no
  keychain itself; it delegates to the `claude` CLI you already run and trust. That is a
  weaker claim than the default build's "cannot phone home," which is exactly why it is
  off by default and isolated to one fenced file.
- **Fails closed.** If `claude` can't be resolved, times out, or the output format
  changes, it silently falls back to the local estimate and shows a gray
  `live unavailable` line (set `TOKENTAB_LIVE_DEBUG=1` for the reason).
- **CLI/SwiftBar only.** An App-Sandboxed native app cannot spawn `claude`, so this
  feature targets the CLI and SwiftBar form factor; the default build and the future
  native app stay pure-local.
- **On the menu bar:** install `swiftbar/token-tab-live.2m.sh` (refreshes every 2 minutes,
  sets `TOKENTAB_LIVE=1`, resolves `claude`). The default `token-tab.30s.sh` is unchanged
  and never spawns anything — `/usage` should not be polled every 30s.

The **local** 5-hour window (above) stays the default everywhere and needs no opt-in.

## Limitations / roadmap

- **Dollars next.** A per-model price-table estimate is the next layer (Bedrock gets its
  own rates).
- **Claude-only** today. A Codex surface (`~/.codex`) is a natural add.
- **Native app** is the keeper: SwiftUI `MenuBarExtra`, App Sandbox, no network
  entitlement, scoped read of `~/.claude/projects`, signed + notarized. The full design
  and review live in the project design doc.

## Develop

```sh
npm test     # node --test, golden-fixture suite for the parser core
```

Architecture: `src/core.mjs` is a pure, I/O-free parser (so tests pin every edge case
without a filesystem); `src/token-tab.mjs` is the thin I/O shell that reads files and
renders. License: MIT.
