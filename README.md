# Token Tab

A provably-safe AI usage meter for the macOS menu bar. It shows your "tab" — the
tokens (later: dollars and rate-limit runway) you've spent with Claude Code — by
reading the session logs already on your disk.

The pitch is not "another usage meter." Those exist (`ccusage`, CodexBar). The pitch
is **a usage meter you can put on a work laptop without worrying.** It makes no network
connections, asks for no keychain access, no API keys, no AWS credentials, and keeps
none of your prompt or response text.

> Status: early. The CLI + SwiftBar plugin work today and reconcile with `ccusage` to
> within 0.003%. The native sandboxed menu-bar app is the roadmap (see below).

## What it does

- Reads `~/.claude/projects/**/*.jsonl` (the transcripts Claude Code already writes).
- Counts tokens per model, per surface (subscription / Bedrock), and per time window
  (today / this week / last 5h).
- Works the same whether Claude Code talks to the Anthropic API, a subscription
  (Max/Pro), or **AWS Bedrock** — the token counts are in the local logs either way,
  so no AWS credentials are needed to read them.

## The trust model (the whole point)

Honest claims, each verifiable:

- **It cannot phone home.** No network code, no dependencies. (The native app will make
  this OS-enforced via App Sandbox with no network entitlement.)
- **It never reads your content.** The parser decodes only the metadata it needs —
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

# 3. It never reads content. The only `.content` mention is a comment, not code
#    (prints nothing):
grep -RnE "\.content" src/ | grep -v "//"

# 4. Confirm the parser reads only metadata: see `recordFromLine` in src/core.mjs
#    — it returns message.id, model, usage, timestamp, isSidechain. Never content.

# 5. Read the whole thing. core.mjs + token-tab.mjs are ~340 lines total.
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

- `TOKENTAB_LOG_DIR` — point at a non-default log directory.
- `CLAUDE_CONFIG_DIR` — respected (reads `$CLAUDE_CONFIG_DIR/projects`).
- Default: `~/.claude/projects`.

## Limitations / roadmap

- **Tokens first.** Dollars (an estimate from a bundled price table) and subscription
  **runway** ("~60% of your 5h window," experimental) are the next layers.
- **Claude-only** today. A Codex surface (`~/.codex`) is a natural add.
- **Native app** is the keeper: SwiftUI `MenuBarExtra`, App Sandbox, no network
  entitlement, scoped read of `~/.claude/projects`, signed + notarized. The full design
  and review live in the project design doc.

## Develop

```sh
npm test     # node --test — golden-fixture suite for the parser core
```

Architecture: `src/core.mjs` is a pure, I/O-free parser (so tests pin every edge case
without a filesystem); `src/token-tab.mjs` is the thin I/O shell that reads files and
renders. License: MIT.
