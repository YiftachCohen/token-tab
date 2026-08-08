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

## Bug hunt

Everything above is a *regression* check: it proves the behavior we already pinned still
holds. `.claude/workflows/bug-hunt.js` is the other half — a Claude Code workflow that goes
looking for behavior nobody has pinned yet.

```
Workflow({name: "bug-hunt"})                        # whole repo, ~34 agents
Workflow({name: "bug-hunt", args: {depth: "quick"}})  # ~15 agents
Workflow({name: "bug-hunt", args: {depth: "deep"}})   # ~68 agents, two rounds
Workflow({name: "bug-hunt", args: {scope: "diff"}})   # only what this branch changed vs main
```

Seven finders hunt one dimension each — JS↔Swift divergence, aggregation/window math,
pricing, the trust invariants a regex can't see, timezone/DST, file IO and the CLI, and
fixtures that prove less than they claim. Every finding is then handed to independent
verifiers that try to *reproduce* it and to *refute* it, and only a majority survives; the
hunt is read-only, so scratch repros go outside the repo. It reports what it dropped at the
cap and ends with a critic on what went unexamined.

It is a hunting tool, not a gate: it does not run in CI, and its findings are candidates to
confirm, not a to-do list. Anything it finds in the two cores almost certainly needs the
AGENTS.md parity treatment — fix both engines, add a shared fixture under
`test/fixtures/parity/`.

## Screenshots

Product images are **rendered, never screenshotted**:

```sh
TOKENTAB_SHOTS=1 swift test --package-path app --filter ShotsTests   # → docs/screenshots/generated/
```

`app/Tests/TokenTabAppTests/Shots/` hosts the real `DropdownView` in an offscreen window over
a procedural wallpaper and captures it — so the glass, the open beat and every number are the
actual shipping views, driven by staged `Snapshot` fixtures rather than the author's `~/.claude`
(a real snapshot leaks project names and can't be re-shot identically after a redesign). Add a
scene to `ShotsTests.scenes()`; add its data to `ShotFixtures`. Skips unless `TOKENTAB_SHOTS=1`,
so CI and a plain `swift test` are unaffected.

Output is gitignored: promote the keepers by hand, as `.webp` so the repo doesn't carry ~400 KB
PNGs (the README's five images cost ~45 KB each this way).

```sh
cwebp -q 90 -m 6 docs/screenshots/generated/hero-subscription-dark.png \
  -o docs/screenshots/menubar-overview.webp
```

Two constraints worth knowing before changing it: `ImageRenderer` is NOT usable here (it
flattens `.thinMaterial` into a grey slab and never fires `onAppear`, freezing every gauge at
0), and capture resolution is the window's backing scale — 2x on a Retina Mac, i.e. exactly
what a Retina screenshot yields.

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
