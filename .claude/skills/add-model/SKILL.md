---
name: add-model
description: Add or update a Claude model's pricing in Token Tab — both engines, the coverage fixture, aliases, and verification. Use when a new Claude model ships, a rate changes, or asked to "add model X", "update pricing", or "new model rate".
---

# Adding or changing a model rate

Token Tab keeps two rate tables in deliberate lockstep (JS + Swift), proven by a shared
coverage fixture and a CI drift check. This skill is the AGENTS.md checklist, executable.

## 0. Get the real rate — never guess

Input/output USD per **1M tokens** from Anthropic's published list pricing (use the
`claude-api` skill or docs.anthropic.com/pricing). Rules of the table:

- **No published rate → no entry.** Unknown models deliberately price as
  `priced:false` ("tracked tokens, untracked price"). Do not invent a number.
- **List price, not promo price.** The table isn't date-aware, so an introductory
  discount would silently go stale (see the Sonnet 5 comment in `src/pricing.mjs`).
- Cache rates are derived (write = 1.25× input, read = 0.10× input) — you only enter
  input and output.

## 1. Edit both engines — same entry, same spot

1. `src/pricing.mjs` → add/update the entry in `RATES` (keep the current/older grouping
   and comment style).
2. `app/Sources/TokenTabCore/Pricing.swift` → mirror it in `rates`, same grouping.
3. If this model becomes its family's latest (a new opus/sonnet/haiku), update the bare
   alias in **both** `ALIASES` (JS) and `aliases` (Swift).

Model ids in the table are canonical: no date suffix, no Bedrock prefixes, no `[1m]`
(e.g. `claude-opus-4-8`). `canonicalModelId` reduces the logged ids to these keys — a new
id *shape* (not just a new model) may need a canonicalization change in both engines too.

## 2. Extend the coverage fixture

`test/fixtures/parity/rates-all-models.json` — the coverage contract both engines run:

1. Add a record: next `ra##`/`rr##` ids, the canonical model id, 1M input + 1M output,
   the fixture's existing future-dated timestamp.
2. `expect.cost.byModel` → add `"<model-id>": <input rate + output rate>`.
3. `expect.total` and `expect.bySurface.subscription` → +2000000 per new record.
4. `expect.cost.total` → add the new model's cost.
5. If you changed an alias target, update the alias record's expected cost too.

## 3. Verify — all four must pass

```sh
node --test                            # includes rates-coverage (set equality both ways)
swift test --package-path app          # Swift twin + shared parity fixtures
node .github/scripts/rates-parity.mjs  # value-level drift check (rates, aliases, multipliers)
bash .github/scripts/trust-audit.sh
```

If `node --test` passes but `swift test` fails coverage (or vice versa), you edited one
engine only — that is exactly the failure loop working; finish the mirror.

## 4. Changelog

The rate table is part of the trust surface: add a line under `## [Unreleased]` in
`CHANGELOG.md` naming the model and rate.
