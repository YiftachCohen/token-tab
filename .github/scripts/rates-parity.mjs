#!/usr/bin/env node
// Token Tab — rate-table drift check.
//
// AGENTS.md's "edit the price tables in lockstep" rule, as a check. The coverage tests
// (rates-coverage.test.mjs / RatesCoverageTests.swift) prove both tables have the same
// KEYS via the shared fixture, and the fixture pins each model's input+output SUM — but
// a value edited in one engine and not the other, a drifted input/output split, or a
// changed cache multiplier can still slip through. This script compares the actual
// numbers: it loads the JS table through its public API and reads the Swift table out
// of Pricing.swift's source (the declarations are data-shaped; if the format ever
// changes, the zero-entries guard below fails loudly rather than passing silently).
//
// Run by ci.yml. No dependencies, no network — same rules as everything else here.

import { readFileSync } from "node:fs";
import { RATED_MODEL_IDS, ALIAS_IDS, ratesFor } from "../../src/pricing.mjs";

const swiftSrc = readFileSync(
  new URL("../../app/Sources/TokenTabCore/Pricing.swift", import.meta.url),
  "utf8",
);

let fail = 0;
const err = (msg) => {
  console.error(`::error::${msg}`);
  fail = 1;
};

// --- Parse the Swift table ---------------------------------------------------------
const swiftRates = {};
for (const m of swiftSrc.matchAll(
  /"([\w.-]+)":\s*Rate\(input:\s*([\d.]+),\s*output:\s*([\d.]+)\)/g,
)) {
  swiftRates[m[1]] = { input: Number(m[2]), output: Number(m[3]) };
}

const aliasBlock = swiftSrc.match(
  /aliases:\s*\[String:\s*String\]\s*=\s*\[([^\]]*)\]/,
);
const swiftAliases = {};
for (const m of (aliasBlock?.[1] ?? "").matchAll(/"([\w-]+)":\s*"([\w-]+)"/g)) {
  swiftAliases[m[1]] = m[2];
}

const swiftWriteMult = Number(swiftSrc.match(/cacheWriteMult\s*=\s*([\d.]+)/)?.[1]);
const swiftReadMult = Number(swiftSrc.match(/cacheReadMult\s*=\s*([\d.]+)/)?.[1]);

if (Object.keys(swiftRates).length === 0 || Object.keys(swiftAliases).length === 0) {
  err(
    "rates-parity.mjs failed to parse Pricing.swift — the declaration format changed; update the regexes in this script",
  );
  process.exit(1);
}

// --- Key sets ------------------------------------------------------------------------
for (const id of RATED_MODEL_IDS)
  if (!(id in swiftRates)) err(`model in src/pricing.mjs but not Pricing.swift: ${id}`);
for (const id of Object.keys(swiftRates))
  if (!RATED_MODEL_IDS.includes(id))
    err(`model in Pricing.swift but not src/pricing.mjs: ${id}`);
for (const id of ALIAS_IDS)
  if (!(id in swiftAliases)) err(`alias in src/pricing.mjs but not Pricing.swift: ${id}`);
for (const id of Object.keys(swiftAliases))
  if (!ALIAS_IDS.includes(id)) err(`alias in Pricing.swift but not src/pricing.mjs: ${id}`);

// --- Values --------------------------------------------------------------------------
for (const id of RATED_MODEL_IDS) {
  const js = ratesFor(id);
  const sw = swiftRates[id];
  if (!sw) continue; // already reported above
  if (js.input !== sw.input || js.output !== sw.output)
    err(
      `rate drift for ${id}: JS input=${js.input}/output=${js.output}, Swift input=${sw.input}/output=${sw.output}`,
    );
}

// Aliases must resolve to the same numbers (i.e. the same family-latest model).
for (const id of ALIAS_IDS) {
  const js = ratesFor(id);
  const sw = swiftRates[swiftAliases[id]];
  if (!sw) continue;
  if (js.input !== sw.input || js.output !== sw.output)
    err(
      `alias drift for "${id}": JS resolves to input=${js.input}/output=${js.output}, Swift → "${swiftAliases[id]}" (input=${sw.input}/output=${sw.output})`,
    );
}

// --- Cache multipliers ----------------------------------------------------------------
// The JS multipliers aren't exported; derive them from any rated model.
const probe = ratesFor(RATED_MODEL_IDS[0]);
const jsWriteMult = probe.cacheWrite / probe.input;
const jsReadMult = probe.cacheRead / probe.input;
if (jsWriteMult !== swiftWriteMult)
  err(`cache-write multiplier drift: JS ${jsWriteMult}, Swift ${swiftWriteMult}`);
if (jsReadMult !== swiftReadMult)
  err(`cache-read multiplier drift: JS ${jsReadMult}, Swift ${swiftReadMult}`);

if (fail) {
  console.error("Rate tables have drifted — edit them in lockstep (see AGENTS.md).");
} else {
  console.log(
    `rate tables mirrored: ${RATED_MODEL_IDS.length} models, ${ALIAS_IDS.length} aliases, multipliers ${jsWriteMult}/${jsReadMult}`,
  );
}
process.exit(fail);
