// Cross-engine parity suite (JS side).
//
// The fixtures in test/fixtures/parity/*.json are a SHARED oracle: the very same
// files are loaded by `swift test` (app/Tests/TokenTabCoreTests/ParityTests.swift).
// Both engines must produce identical shared-subset numbers on identical input, so any
// divergence in dedup, surface routing, windowing, or pricing fails CI in at least one
// engine. This is the safety net that replaces hand-copied "twin" tests (see AGENTS.md).
//
// Only the fields a fixture lists in `expect` are asserted (each side computes extra
// fields the other lacks). Calendar-day fields (today/cost.today) are pinned only where
// they are timezone-independent — see the per-fixture `_comment`s. Synthetic values only.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { aggregate } from "../src/core.mjs";
import { costOfUsage } from "../src/pricing.mjs";

const dir = new URL("./fixtures/parity/", import.meta.url);
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
assert.ok(files.length >= 4, `expected >= 4 parity fixtures, found ${files.length}`);

const FLOAT_TOL = 1e-9; // cost.* are dollars; compare with tolerance, not ===
const approx = (a, b) => Math.abs(a - b) <= FLOAT_TOL;

for (const file of files) {
  const fx = JSON.parse(fs.readFileSync(new URL(file, dir), "utf8"));
  test(`parity: ${fx.name} [${file}]`, () => {
    const a = aggregate(fx.records, {
      now: fx.now,
      cap: fx.cap || undefined, // 0 means "no cap" -> let aggregate default
      cost: costOfUsage, // always injected, so every fixture exercises pricing too
      codexRateLimits: fx.codexRateLimits || undefined,
    });
    const e = fx.expect;

    // Whole-token scalars (assert only the ones this fixture pins).
    for (const k of ["total", "today", "thisWeek", "rolling5h"]) {
      if (k in e) assert.equal(a[k], e[k], k);
    }

    if (e.byClass) {
      for (const k of Object.keys(e.byClass)) {
        assert.equal(a.byClass[k], e.byClass[k], `byClass.${k}`);
      }
    }

    if (e.bySurface) {
      // A surface key only exists once it has tokens, so missing == 0.
      for (const k of Object.keys(e.bySurface)) {
        assert.equal(a.bySurface[k] ?? 0, e.bySurface[k], `bySurface.${k}`);
      }
    }

    // Tokens-per-model: exact map (same keys, same integer counts).
    if (e.byModel) assert.deepEqual(a.byModel, e.byModel);

    if (e.window) {
      const w = e.window;
      if ("active" in w) assert.equal(a.window.active, w.active, "window.active");
      if ("tokens" in w) assert.equal(a.window.tokens, w.tokens, "window.tokens");
      if ("calibratedCap" in w) assert.equal(a.window.calibratedCap, w.calibratedCap, "window.calibratedCap");
      // JS exposes resetAt already as epoch ms (or null when idle).
      if ("resetMs" in w) assert.equal(a.window.resetAt, w.resetMs, "window.resetMs");
      if ("pct" in w) assert.equal(a.window.pct, w.pct, "window.pct");
    }

    if (e.providerOrder) assert.deepEqual(a.providerOrder, e.providerOrder, "providerOrder");

    if (e.providers) {
      for (const p of Object.keys(e.providers)) {
        const pb = a.providers[p];
        assert.ok(pb, `providers.${p} present`);
        const ep = e.providers[p];
        for (const k of ["today", "total", "thisWeek", "rolling5h"]) {
          if (k in ep) assert.equal(pb[k], ep[k], `providers.${p}.${k}`);
        }
        if (ep.byClass) {
          for (const k of Object.keys(ep.byClass)) {
            assert.equal(pb.byClass[k], ep.byClass[k], `providers.${p}.byClass.${k}`);
          }
        }
        if (ep.byModel) assert.deepEqual(pb.byModel, ep.byModel, `providers.${p}.byModel`);
        if (ep.bySurface) {
          for (const k of Object.keys(ep.bySurface)) {
            assert.equal(pb.bySurface[k] ?? 0, ep.bySurface[k], `providers.${p}.bySurface.${k}`);
          }
        }
        if (ep.windows) {
          for (const wk of Object.keys(ep.windows)) {
            const w = pb.windows?.[wk];
            const ew = ep.windows[wk];
            assert.ok(w, `providers.${p}.windows.${wk} present`);
            if ("source" in ew) assert.equal(w.source, ew.source, `providers.${p}.windows.${wk}.source`);
            if ("period" in ew) assert.equal(w.period, ew.period, `providers.${p}.windows.${wk}.period`);
            if ("usedPct" in ew) assert.equal(w.usedPct, ew.usedPct, `providers.${p}.windows.${wk}.usedPct`);
            if ("windowMinutes" in ew) assert.equal(w.windowMinutes, ew.windowMinutes, `providers.${p}.windows.${wk}.windowMinutes`);
            if ("cap" in ew) assert.equal(w.cap, ew.cap, `providers.${p}.windows.${wk}.cap`);
            if ("calibratedCap" in ew) assert.equal(w.calibratedCap, ew.calibratedCap, `providers.${p}.windows.${wk}.calibratedCap`);
            if ("resetAtMs" in ew) {
              const actualMs = w.resetAt == null ? null : new Date(w.resetAt).getTime();
              assert.equal(actualMs, ew.resetAtMs, `providers.${p}.windows.${wk}.resetAtMs`);
            }
          }
        }
        if (ep.plan) {
          assert.ok(pb.plan, `providers.${p}.plan present`);
          if ("planType" in ep.plan) assert.equal(pb.plan.planType, ep.plan.planType, `providers.${p}.plan.planType`);
          if ("asOfMs" in ep.plan) {
            const actualMs = pb.plan.asOf == null ? null : new Date(pb.plan.asOf).getTime();
            assert.equal(actualMs, ep.plan.asOfMs, `providers.${p}.plan.asOfMs`);
          }
        }
      }
    }

    if (e.cost) {
      const c = e.cost;
      assert.ok(a.cost, "cost block present (a cost fn was injected)");
      if ("total" in c) assert.ok(approx(a.cost.total, c.total), `cost.total ${a.cost.total} != ${c.total}`);
      if ("today" in c) assert.ok(approx(a.cost.today, c.today), `cost.today ${a.cost.today} != ${c.today}`);
      if ("unpricedTokens" in c) assert.equal(a.cost.unpriced.tokens, c.unpricedTokens, "cost.unpricedTokens");
      if (c.byModel) {
        assert.deepEqual(
          Object.keys(a.cost.byModel).sort(),
          Object.keys(c.byModel).sort(),
          "cost.byModel keys",
        );
        for (const k of Object.keys(c.byModel)) {
          assert.ok(approx(a.cost.byModel[k], c.byModel[k]), `cost.byModel[${k}] ${a.cost.byModel[k]} != ${c.byModel[k]}`);
        }
      }
    }
  });
}
