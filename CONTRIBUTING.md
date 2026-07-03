# Contributing to Token Tab

Thanks for helping. Token Tab is small on purpose — one dependency-free parser,
ported once, behind three front-ends — and its whole value is a set of trust
invariants. Most contributions are easy; the rules below exist so the product's
core claim ("it has no way to leak anything") survives every PR.

## The non-negotiables

These are CI-enforced (the `audit` job in `.github/workflows/ci.yml`) and a PR
that breaks one will not merge. Full detail in [`AGENTS.md`](AGENTS.md):

1. **Zero runtime dependencies.** `package.json` `dependencies` stays `{}`;
   `app/Package.swift` declares no SwiftPM dependencies.
2. **No network, no subprocess in `src/`.** The only subprocess in the repo is
   the opt-in live reader, fenced in `adapters/`.
3. **Never read message content.** The parser touches token metadata only —
   never `message.content`.
4. **The native app cannot phone home.** `app/Bundle/TokenTab.entitlements`
   grants no network entitlement, and `app/Sources` contains no
   network/subprocess APIs (keep raw `http(s)://` URLs out of comments there
   too, so the audit greps stay clean).

Run the audit yourself before pushing — the greps are listed in
[`AGENTS.md`](AGENTS.md#invariants-do-not-break-these) and in the README's
[Audit it yourself](README.md#audit-it-yourself) section.

## Two engines, one behavior

The JS core (`src/core.mjs` + `src/pricing.mjs`) and the Swift port
(`app/Sources/TokenTabCore/`) are kept in deliberate parity. Any behavior
change — dedup, surface routing, windowing, rate table, canonicalization —
must land in **both** engines in the same PR, pinned by a shared fixture in
`test/fixtures/parity/` that both test suites load.

Adding or changing a model rate has a four-step checklist in
[`AGENTS.md`](AGENTS.md#two-engines-one-behavior); the coverage tests fail
loudly if you miss a step.

## Setup and tests

You need Node ≥ 18. The Swift side needs macOS with Xcode command-line tools.

```sh
node --test                       # JS engine + CLI tests
swift test --package-path app     # Swift engine + parity tests
```

There is nothing to install — no `npm install`, no build step for the CLI.
The native app builds with `app/Scripts/build-app.sh` (see
[`app/README.md`](app/README.md)).

A timezone note: `today` / `cost.today` are local-calendar values. CI runs the
suites under UTC, Pacific/Auckland, and America/Los_Angeles — don't pin those
fields in a fixture unless it's timezone-independent.

## UI changes

Read [`DESIGN.md`](DESIGN.md) first. All font, color, spacing, and motion
decisions are defined there (design tokens live in
`app/Sources/TokenTab/Views/Theme.swift`); PRs that deviate from it will be
asked to conform or to make the case for changing `DESIGN.md` itself.

## Pull requests

- Keep them focused; separate behavior changes from refactors.
- New behavior gets a test — for engine behavior, a parity fixture.
- If you touched anything the README documents (flags, env vars, output
  formats), update the README in the same PR.
- Accuracy claims matter here: if your change moves any total, say why in the
  PR description and reconcile against `ccusage` or Claude's `/usage` where
  applicable.

## Questions

Open a [Discussion](https://github.com/YiftachCohen/token-tab/discussions) for
questions and ideas, an issue for bugs. Security reports go through
[`SECURITY.md`](SECURITY.md), not public issues.
