// Rate-table coverage contract (JS side).
//
// The shared parity fixture test/fixtures/parity/rates-all-models.json must carry one
// record per model the engine can price — every RATES key and every ALIASES key. This
// test asserts SET EQUALITY both ways, so the failure loop closes: add a model to
// src/pricing.mjs and forget the fixture -> red here ("add a record"); add a model to the
// fixture with no rate behind it -> also red here ("add the rate to BOTH engines"). The
// mirror-image RatesCoverageTests.swift enforces the same against the Swift table, so a
// model added to one engine but not the other cannot ship green. Synthetic values only.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { RATED_MODEL_IDS, ALIAS_IDS } from "../src/pricing.mjs";

const fx = JSON.parse(
  fs.readFileSync(
    new URL("./fixtures/parity/rates-all-models.json", import.meta.url),
    "utf8",
  ),
);
const fixtureModels = fx.records.map((r) => r.model);
const tableModels = [...RATED_MODEL_IDS, ...ALIAS_IDS];

test("rates-all-models.json has no duplicate model records", () => {
  const seen = new Set();
  const dups = fixtureModels.filter((m) => (seen.has(m) ? true : (seen.add(m), false)));
  assert.deepEqual(dups, [], `duplicate model records in the fixture: ${dups.join(", ")}`);
});

test("rates-all-models.json covers the JS rate table exactly", () => {
  const fixtureSet = new Set(fixtureModels);
  const tableSet = new Set(tableModels);

  // A table key with no fixture record -> the cost of that model is never parity-checked.
  for (const id of tableSet) {
    assert.ok(
      fixtureSet.has(id),
      `src/pricing.mjs has a model the coverage fixture doesn't: ${id}. Add a record for it to test/fixtures/parity/rates-all-models.json (1M input + 1M output; expected cost = input+output rate) — AND mirror the model in app/Sources/TokenTabCore/Pricing.swift.`,
    );
  }

  // A fixture record with no table entry -> a phantom model that prices as unknown.
  for (const id of fixtureSet) {
    assert.ok(
      tableSet.has(id),
      `rates-all-models.json has a model src/pricing.mjs doesn't: ${id}. Either remove it or add the rate to RATES/ALIASES in BOTH engines.`,
    );
  }
});
