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
// Both engines keep ONE table per provider (Claude list pricing, OpenAI/Codex list
// pricing) plus per-provider cache multipliers, so every comparison below is scoped to a
// provider — a Codex model must never be checked against the Claude table.
//
// Run by ci.yml. No dependencies, no network — same rules as everything else here.

import { readFileSync } from "node:fs";
import { ratedModelIds, aliasIds, ratesFor } from "../../src/pricing.mjs";

const swiftSrc = readFileSync(
  new URL("../../app/Sources/TokenTabCore/Pricing.swift", import.meta.url),
  "utf8",
);

let fail = 0;
const err = (msg) => {
  console.error(`::error::${msg}`);
  fail = 1;
};

// --- Swift source parsing -------------------------------------------------------------
// Each table is a `static let <name>: [...] = [ ... ]`. Grab a declaration's bracket
// block by scanning depth from the `=`'s opening `[`, so one table's entries can never
// bleed into another's (the whole point of the provider scoping).
function declBlock(name) {
  const decl = new RegExp(`let\\s+${name}\\s*:\\s*\\[[^\\]]*\\]\\s*=\\s*\\[`).exec(swiftSrc);
  if (!decl) return null;
  let depth = 1;
  const start = decl.index + decl[0].length;
  for (let i = start; i < swiftSrc.length; i++) {
    if (swiftSrc[i] === "[") depth++;
    else if (swiftSrc[i] === "]" && --depth === 0) return swiftSrc.slice(start, i);
  }
  return null;
}

function parseRates(name) {
  const src = declBlock(name);
  if (src === null) return null;
  const out = {};
  for (const m of src.matchAll(
    /"([\w.-]+)":\s*Rate\(input:\s*([\d.]+),\s*output:\s*([\d.]+)\)/g,
  )) {
    out[m[1]] = { input: Number(m[2]), output: Number(m[3]) };
  }
  return out;
}

function parseAliases(name) {
  const src = declBlock(name);
  if (src === null) return null;
  const out = {};
  for (const m of src.matchAll(/"([\w.-]+)":\s*"([\w.-]+)"/g)) out[m[1]] = m[2];
  return out;
}

// Per-provider cache multipliers: "claude": CacheMult(write: 1.25, read: 0.10), ...
function parseCacheMults() {
  const src = declBlock("cacheMultipliers");
  if (src === null) return null;
  const out = {};
  for (const m of src.matchAll(
    /"(\w+)":\s*CacheMult\(write:\s*([\d.]+),\s*read:\s*([\d.]+)\)/g,
  )) {
    out[m[1]] = { write: Number(m[2]), read: Number(m[3]) };
  }
  return out;
}

// provider -> the Swift declaration names holding its table. Add a provider here when
// pricing.mjs's TABLES gains one, or this check silently stops covering it.
const PROVIDERS = {
  claude: { rates: "rates", aliases: "aliases" },
  codex: { rates: "openAIRates", aliases: "openAIAliases" },
};

const swiftMults = parseCacheMults();
if (!swiftMults || Object.keys(swiftMults).length === 0) {
  err(
    "rates-parity.mjs failed to parse cacheMultipliers in Pricing.swift — the declaration format changed; update the regexes in this script",
  );
  process.exit(1);
}

let totalModels = 0;
let totalAliases = 0;

for (const [provider, decls] of Object.entries(PROVIDERS)) {
  const swiftRates = parseRates(decls.rates);
  // parseAliases returns {} for a declaration that exists but is empty (`[:]`, which is
  // openAIAliases today) and null only when the declaration is missing outright — so a
  // renamed table fails loudly instead of reading as "no aliases, all good".
  const swiftAliases = parseAliases(decls.aliases);

  if (swiftRates === null || swiftAliases === null) {
    err(
      `rates-parity.mjs failed to parse the ${provider} table (${decls.rates}/${decls.aliases}) in Pricing.swift — the declaration format changed; update this script`,
    );
    continue;
  }
  if (Object.keys(swiftRates).length === 0) {
    err(`rates-parity.mjs parsed ZERO ${provider} models out of Pricing.swift — format changed`);
    continue;
  }

  const jsRated = ratedModelIds(provider);
  const jsAliases = aliasIds(provider);
  totalModels += jsRated.length;
  totalAliases += jsAliases.length;

  // --- Key sets ---------------------------------------------------------------------
  for (const id of jsRated)
    if (!(id in swiftRates))
      err(`[${provider}] model in src/pricing.mjs but not Pricing.swift: ${id}`);
  for (const id of Object.keys(swiftRates))
    if (!jsRated.includes(id))
      err(`[${provider}] model in Pricing.swift but not src/pricing.mjs: ${id}`);
  for (const id of jsAliases)
    if (!(id in swiftAliases))
      err(`[${provider}] alias in src/pricing.mjs but not Pricing.swift: ${id}`);
  for (const id of Object.keys(swiftAliases))
    if (!jsAliases.includes(id))
      err(`[${provider}] alias in Pricing.swift but not src/pricing.mjs: ${id}`);

  // --- Values -----------------------------------------------------------------------
  for (const id of jsRated) {
    const js = ratesFor(id, provider);
    const sw = swiftRates[id];
    if (!sw) continue; // already reported above
    if (js.input !== sw.input || js.output !== sw.output)
      err(
        `[${provider}] rate drift for ${id}: JS input=${js.input}/output=${js.output}, Swift input=${sw.input}/output=${sw.output}`,
      );
  }

  // Aliases must resolve to the same numbers (i.e. the same family-latest model).
  for (const id of jsAliases) {
    const js = ratesFor(id, provider);
    const sw = swiftRates[swiftAliases[id]];
    if (!sw) continue;
    if (js.input !== sw.input || js.output !== sw.output)
      err(
        `[${provider}] alias drift for "${id}": JS resolves to input=${js.input}/output=${js.output}, Swift → "${swiftAliases[id]}" (input=${sw.input}/output=${sw.output})`,
      );
  }

  // --- Cache multipliers --------------------------------------------------------------
  // The JS multipliers aren't exported; derive them from any rated model of this provider.
  const sw = swiftMults[provider];
  if (!sw) {
    err(`[${provider}] no cacheMultipliers entry in Pricing.swift`);
    continue;
  }
  const probe = ratesFor(jsRated[0], provider);
  const jsWrite = probe.cacheWrite / probe.input;
  const jsRead = probe.cacheRead / probe.input;
  if (jsWrite !== sw.write)
    err(`[${provider}] cache-write multiplier drift: JS ${jsWrite}, Swift ${sw.write}`);
  if (jsRead !== sw.read)
    err(`[${provider}] cache-read multiplier drift: JS ${jsRead}, Swift ${sw.read}`);
}

// A provider priced in Swift but absent from PROVIDERS above would never be compared.
for (const p of Object.keys(swiftMults))
  if (!(p in PROVIDERS))
    err(`provider "${p}" has cache multipliers in Pricing.swift but no entry in rates-parity.mjs's PROVIDERS map`);

if (fail) {
  console.error("Rate tables have drifted — edit them in lockstep (see AGENTS.md).");
} else {
  console.log(
    `rate tables mirrored across ${Object.keys(PROVIDERS).length} providers: ${totalModels} models, ${totalAliases} aliases`,
  );
}
process.exit(fail);
