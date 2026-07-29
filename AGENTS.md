# AGENTS.md — working rules for Token Tab

Token Tab shows Claude Code token usage in the macOS menu bar by reading the
local logs Claude Code already writes (`~/.claude/projects/**/*.jsonl`). Its whole
value is a set of **trust invariants**. Breaking one silently breaks the product's
core claim, so they are non-negotiable and CI-enforced (see `.github/workflows/ci.yml`).

## Invariants (do not break these)

1. **Zero runtime dependencies.** `package.json` `dependencies` must stay `{}`.
   No npm packages, no SwiftPM dependencies in `app/Package.swift`.
2. **No network and no subprocess in the audited JS core (`src/`).** These greps
   over `src/` must print nothing:
   - `grep -RnE "fetch|http|https|net\.|URLSession|Socket|dns" src/`
   - `grep -RnE "child_process|spawn|execFile" src/`
   The only subprocesses in the repo are the two opt-in live paths, each
   deliberately fenced outside its audited tree: `adapters/claude-live.mjs`
   (JS, enabled by `TOKENTAB_LIVE`, outside `src/`) and `app/Helper/main.swift`
   (the bundled live helper, registered via the in-app Live % toggle, outside
   `app/Sources`). Both do exactly one thing: run `claude -p "/usage"` and
   write the parsed percentages to the local cache file.
3. **Never read message content.** The parser decodes only token metadata
   (`type`, `model`, `message.id`, `requestId`, `usage`, `timestamp`,
   `isSidechain`). It must never touch `message.content`.
   `grep -RnE "\.content" src/ | grep -v "//"` must print nothing, and the Swift
   `LogReader.Line` Codable struct must have no `content` field.
4. **The native app cannot phone home (OS-enforced).** `app/Bundle/TokenTab.entitlements`
   grants only `app-sandbox` + `files.user-selected.read-only` — no network
   entitlement. `app/Sources` must contain no network/subprocess APIs:
   - `grep -RnE "URLSession|NWConnection|CFSocket|getaddrinfo|Socket" app/Sources`
   - `grep -RnE "Process\(|posix_spawn|NSTask|popen|execv" app/Sources`
   must print nothing. (Don't put raw `http(s)://` URLs in `app/Sources` comments —
   reference docs from markdown instead — so the audit stays clean.)

## Two engines, one behavior

There are **two parsing engines kept in deliberate parity**:

- JS: `src/core.mjs` + `src/pricing.mjs` (the audited core; powers the CLI and
  the SwiftBar plugin).
- Swift: `app/Sources/TokenTabCore/Core.swift` + `Pricing.swift` (powers the
  native app).

Any change to one engine's behavior (dedup, surface routing, windowing, rate
table, canonicalization) **must** be mirrored in the other, and every JS test
fixture (`test/core.test.mjs`) should have a Swift twin (`app/Tests/TokenTabCoreTests/CoreTests.swift`).
The price/classifier tables are hand-mirrored across the two files — edit them in
lockstep.

**Shared parity fixtures.** The JSON files in `test/fixtures/parity/*.json` are the
proof of parity: each holds input records plus the expected shared-subset aggregate, and
**both** runners load the same files — `node --test` via `test/parity.test.mjs` and
`swift test` via `app/Tests/TokenTabCoreTests/ParityTests.swift`. A change to dedup,
surface routing, windowing, or the rate tables must keep both green; surface a new
behavior by adding a fixture there rather than hand-copying another twin test. (Each
fixture asserts only the fields it pins; `today`/`cost.today` are local-calendar values,
so pin them only where a fixture is timezone-independent.)

**Adding or changing a model rate — checklist:**
1. `src/pricing.mjs` — add/update the entry in `RATES` (and `ALIASES` if a bare
   alias should resolve to it).
2. `app/Sources/TokenTabCore/Pricing.swift` — mirror the same entry in
   `rates`/`aliases`.
3. `test/fixtures/parity/rates-all-models.json` — add a record for it (1M input
   + 1M output tokens) and its `cost.byModel` line (= input rate + output rate);
   update `total`, `bySurface`, and `cost.total`.
4. `node --test && swift test --package-path app` — the coverage tests
   (`test/rates-coverage.test.mjs`, `RatesCoverageTests.swift`) fail loudly if
   any of the three is missing — then `node .github/scripts/rates-parity.mjs`,
   which catches value drift the key-level coverage can't.

## Build / test / audit

```sh
node --test                            # JS engine tests (also the CLI/IO tests)
swift test --package-path app          # Swift engine parity tests
bash .github/scripts/trust-audit.sh    # the invariant greps, as one script
node .github/scripts/rates-parity.mjs  # value-level JS↔Swift rate-table drift check
bash .github/scripts/design-lint.sh    # no new raw color/font literals outside Theme.swift
```

CI (`ci.yml`) runs all of these; the `audit` job fails if any grep is non-empty. A
Claude Code hook (`.claude/hooks/guard-audited-trees.sh`, wired in `.claude/settings.json`)
re-runs the audit + design lint automatically after any edit to `src/`, `app/Sources/`,
or `package.json`, so violations surface at edit time — but run the suite yourself
before pushing anyway.

The design lint is a ratchet: literals that predate it are listed in
`.github/scripts/design-lint-baseline.txt` (each is a migration TODO — move it into
`Theme.swift` and delete its line). Never add to the baseline.

**Skills** (Claude Code, in `.claude/skills/`): `release` — the full RELEASING.md flow
with the signing/npm/Homebrew gotchas baked in; `add-model` — the rate checklist below,
executable.

## Layout

- `src/` — JS engine + CLI (`token-tab.mjs`), pricing, live-output parser. Audited core.
- `adapters/` — the ONLY network/subprocess code (opt-in live `/usage` reader + cache writer).
- `app/` — native SwiftUI menu-bar app (SwiftPM). `Sources/TokenTabCore` is the pure port.
- `swiftbar/` — SwiftBar shell wrappers.
- `test/` — JS tests. `plans/` — advisor implementation plans.
