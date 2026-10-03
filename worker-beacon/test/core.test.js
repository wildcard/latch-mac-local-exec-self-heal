import test from "node:test";
import assert from "node:assert/strict";
import { accept, consume, emptyState, validateBody } from "../src/core.js";

const NOW = 1_800_000_000;
const J1 = "11111111-1111-4111-8111-111111111111";
const J2 = "22222222-2222-4222-8222-222222222222";
const body = (o = {}) => ({ v: 1, action: "heal_request", machineId: "m1", jti: J1, exp: NOW + 60, ...o });

test("valid request is accepted and consumed once", () => {
  const a = accept(emptyState(), body(), NOW);
  assert.equal(a.status, 202);
  const c1 = consume(a.state, NOW + 1);
  assert.equal(c1.heal, true);
  assert.equal(consume(c1.state, NOW + 2).heal, false);
});

test("extra fields, other actions, bad types rejected and nothing stored", () => {
  for (const b of [body({ cmd: "rm -rf /" }), body({ action: "shell" }), body({ v: 2 }), body({ jti: "x" }), body({ exp: "9" }), null, []]) {
    const r = accept(emptyState(), b, NOW);
    assert.equal(r.status, 400);
    assert.equal(r.state.pending, null);
  }
  const { cmd, ...missing } = body({ cmd: 1 }); delete missing.jti;
  assert.ok(validateBody(missing));
});

test("expired and too-far exp rejected", () => {
  assert.equal(accept(emptyState(), body({ exp: NOW - 1 }), NOW).status, 400);
  assert.equal(accept(emptyState(), body({ exp: NOW + 121 }), NOW).status, 400);
  assert.equal(accept(emptyState(), body({ exp: NOW + 120 }), NOW).status, 202);
});

test("replayed jti rejected", () => {
  const a = accept(emptyState(), body(), NOW);
  consume(a.state, NOW + 1);
  assert.equal(accept(a.state, body(), NOW + 30).status, 409);
});

test("rate limit: 5 min gap and 3/hour", () => {
  let s = accept(emptyState(), body(), NOW).state;
  assert.equal(accept(s, body({ jti: J2, exp: NOW + 100 }), NOW + 40).status, 429);
  const ids = ["33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"];
  let t = NOW;
  const results = ids.map((jti) => { t += 301; const r = accept(s, body({ jti, exp: t + 60 }), t); s = r.state; return r.status; });
  assert.deepEqual(results, [202, 202, 429]); // 1 + 2 = 3 accepted in the hour, 4th blocked
});

test("second accepted request refreshes the single pending flag, never stacks", () => {
  let s = accept(emptyState(), body(), NOW).state;
  s = accept(s, body({ jti: J2, exp: NOW + 400 + 60 }), NOW + 400).state;
  assert.equal(consume(s, NOW + 401).heal, true);
  assert.equal(consume(consume(s, NOW + 401).state, NOW + 402).heal, false);
});

test("expired pending flag is not returned", () => {
  const a = accept(emptyState(), body(), NOW);
  assert.equal(consume(a.state, NOW + 61).heal, false);
});
