// Tests for the live-cache writer's PURE helpers (adapters/write-live.mjs).
//
// We never spawn `claude` here — only the serializer and path resolver are exercised.
// The shape pinned here is the exact contract the Swift LiveReader decodes, so a drift on
// either side breaks a test. Run: `node --test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { homedir } from "node:os";
import { serializeLive, liveCachePath } from "../adapters/write-live.mjs";

const READING = {
  source: "claude /usage",
  sessionPct: 9,
  sessionResetText: "12:29am (Europe/Rome)",
  weeklyPct: 18,
  weeklyResetText: "Jun 27 at 6:59am (Europe/Rome)",
  weeklyByModel: { sonnet: 0 },
};

test("serializeLive: full reading round-trips to the on-disk contract", () => {
  const obj = JSON.parse(serializeLive(READING, "2026-06-23T10:15:00.000Z"));
  assert.equal(obj.schema, 1);
  assert.equal(obj.source, "claude /usage");
  assert.equal(obj.capturedAt, "2026-06-23T10:15:00.000Z");
  assert.equal(obj.sessionPct, 9);
  assert.equal(obj.sessionResetText, "12:29am (Europe/Rome)");
  assert.equal(obj.weeklyPct, 18);
  assert.deepEqual(obj.weeklyByModel, { sonnet: 0 });
});

test("serializeLive: null/empty reading writes nothing (fail closed)", () => {
  assert.equal(serializeLive(null, "2026-06-23T10:15:00.000Z"), null);
  assert.equal(serializeLive({ weeklyByModel: {} }, "2026-06-23T10:15:00.000Z"), null,
    "no session and no weekly % → nothing worth writing");
});

test("serializeLive: a lone session % is enough to write", () => {
  const obj = JSON.parse(serializeLive({ sessionPct: 3 }, "2026-06-23T10:15:00.000Z"));
  assert.equal(obj.sessionPct, 3);
  assert.equal(obj.weeklyPct, null, "missing fields normalize to null, not undefined");
  assert.deepEqual(obj.weeklyByModel, {});
});

test("liveCachePath: defaults under ~/.claude/projects", () => {
  assert.equal(liveCachePath({}), join(homedir(), ".claude", "projects", ".token-tab-live.json"));
});

test("liveCachePath: honors TOKENTAB_LOG_DIR and CLAUDE_CONFIG_DIR and an explicit override", () => {
  assert.equal(liveCachePath({ TOKENTAB_LOG_DIR: "/tmp/logs" }), "/tmp/logs/.token-tab-live.json");
  assert.equal(liveCachePath({ CLAUDE_CONFIG_DIR: "/c" }), join("/c", "projects", ".token-tab-live.json"));
  assert.equal(liveCachePath({ TOKENTAB_LIVE_CACHE: "/x/y.json" }), "/x/y.json");
});
