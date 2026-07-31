// Rate-table coverage contract (JS side).
//
// The shared parity fixtures test/fixtures/parity/rates-all-models.json (Claude) and
// rates-all-models-codex.json (Codex) must together carry one record per (provider, model)
// the engine can price — every RATES/ALIASES key under "claude" and every OPENAI_RATES key
// under "codex". This test asserts SET EQUALITY both ways per provider, so the failure loop
// closes: add a model to src/pricing.mjs and forget the fixture -> red here ("add a
// record"); add a model to a fixture with no rate behind it -> also red here ("add the
// rate to BOTH engines"). The mirror-image RatesCoverageTests.swift enforces the same
// against the Swift tables, so a model added to one engine but not the other cannot ship
// green. Synthetic values only.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {
  RATED_MODEL_IDS,
  ALIAS_IDS,
  OPENAI_RATED_MODEL_IDS,
} from "../src/pricing.mjs";

function loadFixture(name) {
  return JSON.parse(
    fs.readFileSync(new URL(`./fixtures/parity/${name}`, import.meta.url), "utf8"),
  );
}

// (provider, model) pairs the fixtures carry, and the ones the JS tables expect.
const claudeFx = loadFixture("rates-all-models.json");
const codexFx = loadFixture("rates-all-models-codex.json");

const fixturePairs = [
  ...claudeFx.records.map((r) => `claude:${r.model}`),
  ...codexFx.records.map((r) => `${r.provider ?? "claude"}:${r.model}`),
];

const tablePairs = [
  ...[...RATED_MODEL_IDS, ...ALIAS_IDS].map((m) => `claude:${m}`),
  ...OPENAI_RATED_MODEL_IDS.map((m) => `codex:${m}`),
];

test("rates-all-models.json has no duplicate model records", () => {
  const seen = new Set();
  const models = claudeFx.records.map((r) => r.model);
  const dups = models.filter((m) => (seen.has(m) ? true : (seen.add(m), false)));
  assert.deepEqual(dups, [], `duplicate model records in the fixture: ${dups.join(", ")}`);
});

test("rates-all-models-codex.json has no duplicate model records", () => {
  const seen = new Set();
  const models = codexFx.records.map((r) => r.model);
  const dups = models.filter((m) => (seen.has(m) ? true : (seen.add(m), false)));
  assert.deepEqual(dups, [], `duplicate model records in the fixture: ${dups.join(", ")}`);
});

test("rates fixtures cover the JS rate tables exactly, per (provider, model)", () => {
  const fixtureSet = new Set(fixturePairs);
  const tableSet = new Set(tablePairs);

  // A table key with no fixture record -> the cost of that model is never parity-checked.
  for (const id of tableSet) {
    assert.ok(
      fixtureSet.has(id),
      `src/pricing.mjs has a (provider, model) the coverage fixtures don't: ${id}. Add a record for it to the matching test/fixtures/parity/rates-all-models*.json (1M input + 1M output; expected cost = input+output rate) — AND mirror the model in app/Sources/TokenTabCore/Pricing.swift.`,
    );
  }

  // A fixture record with no table entry -> a phantom model that prices as unknown.
  for (const id of fixtureSet) {
    assert.ok(
      tableSet.has(id),
      `a rates-all-models*.json fixture has a (provider, model) src/pricing.mjs doesn't: ${id}. Either remove it or add the rate to the matching table in BOTH engines.`,
    );
  }
});

// Regression guard (design doc section 3): these ids are deliberately unpriced, for two
// distinct reasons. gpt-5.3-codex-spark (research preview, rates explicitly "not final"),
// gpt-5.4-codex (no such published model — a few stray log records) and codex-auto-review
// (an internal Codex slug) have NO published rate we can verify; the two "-pro" ids are
// priced but aren't Codex CLI models. Either way a guessed price is worse than an honest
// "unknown", so this must stay red if any of them is ever added to OPENAI_RATES.
test("known-unpriced Codex/legacy models are absent from the rate tables", () => {
  const claudeTable = new Set([...RATED_MODEL_IDS, ...ALIAS_IDS]);
  const codexTable = new Set(OPENAI_RATED_MODEL_IDS);
  const shouldBeUnpriced = [
    "gpt-5.4-pro",
    "gpt-5.5-pro",
    "gpt-5.3-codex-spark",
    "gpt-5.4-codex",
    "codex-auto-review",
  ];
  for (const id of shouldBeUnpriced) {
    assert.ok(!claudeTable.has(id), `${id} must stay out of the Claude rate table`);
    assert.ok(!codexTable.has(id), `${id} must stay out of the Codex rate table`);
  }
});
