import test from "node:test";
import assert from "node:assert/strict";
import worker, { Inbox } from "../src/index.js";

const WRITER = "writer-secret-token";
const POLLER = "poller-secret-token";
const MID = "m1";

function memoryInbox() {
  const store = new Map();
  const state = {
    storage: {
      async get(k) { return store.has(k) ? store.get(k) : undefined; },
      async put(k, v) { store.set(k, v); },
    },
  };
  const inbox = new Inbox(state);
  return {
    get(_id) {
      return {
        fetch(url, init) {
          return inbox.fetch(new Request(url, init));
        },
      };
    },
    idFromName(name) { return { name }; },
  };
}

function env(extra = {}) {
  return {
    WRITER_TOKEN: WRITER,
    POLLER_TOKEN: POLLER,
    ALLOWED_MACHINE_IDS: MID,
    INBOX: memoryInbox(),
    ...extra,
  };
}

function req(path, { token, body, method = "POST" } = {}) {
  const headers = { "content-type": "application/json" };
  if (token !== undefined) headers.authorization = `Bearer ${token}`;
  return new Request("https://beacon.test" + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const healBody = (o = {}) => ({
  v: 1,
  action: "heal_request",
  machineId: MID,
  jti: "11111111-1111-4111-8111-111111111111",
  exp: Math.floor(Date.now() / 1000) + 60,
  ...o,
});

test("missing or wrong bearer is 401", async () => {
  const e = env();
  assert.equal((await worker.fetch(req("/v1/heal-request", { body: healBody() }), e)).status, 401);
  assert.equal((await worker.fetch(req("/v1/heal-request", { token: "nope", body: healBody() }), e)).status, 401);
  assert.equal((await worker.fetch(req("/v1/poll", { token: "nope", body: { machineId: MID } }), e)).status, 401);
});

test("writer token cannot poll; poller token cannot heal-request", async () => {
  const e = env();
  assert.equal((await worker.fetch(req("/v1/poll", { token: WRITER, body: { machineId: MID } }), e)).status, 401);
  assert.equal((await worker.fetch(req("/v1/heal-request", { token: POLLER, body: healBody() }), e)).status, 401);
});

test("unknown machine is 403 for both routes", async () => {
  const e = env();
  const h = await worker.fetch(req("/v1/heal-request", { token: WRITER, body: healBody({ machineId: "other" }) }), e);
  const p = await worker.fetch(req("/v1/poll", { token: POLLER, body: { machineId: "other" } }), e);
  assert.equal(h.status, 403);
  assert.equal(p.status, 403);
});

test("bad JSON is 400", async () => {
  const e = env();
  const r = await worker.fetch(new Request("https://beacon.test/v1/heal-request", {
    method: "POST",
    headers: { authorization: `Bearer ${WRITER}`, "content-type": "application/json" },
    body: "{not-json",
  }), e);
  assert.equal(r.status, 400);
});

test("GET is 404; unknown path is 404", async () => {
  const e = env();
  const get = new Request("https://beacon.test/v1/heal-request", {
    method: "GET",
    headers: { authorization: `Bearer ${WRITER}` },
  });
  assert.equal((await worker.fetch(get, e)).status, 404);
  assert.equal((await worker.fetch(req("/v1/other", { token: WRITER, body: healBody() }), e)).status, 404);
});

test("accept then poll consume-once via Worker routing", async () => {
  const e = env();
  const a = await worker.fetch(req("/v1/heal-request", { token: WRITER, body: healBody() }), e);
  assert.equal(a.status, 202);
  const p1 = await worker.fetch(req("/v1/poll", { token: POLLER, body: { machineId: MID } }), e);
  assert.equal(p1.status, 200);
  assert.deepEqual(await p1.json(), { heal: true });
  const p2 = await worker.fetch(req("/v1/poll", { token: POLLER, body: { machineId: MID } }), e);
  assert.deepEqual(await p2.json(), { heal: false });
});

test("unset secrets reject all callers", async () => {
  const e = env({ WRITER_TOKEN: "", POLLER_TOKEN: "" });
  assert.equal((await worker.fetch(req("/v1/heal-request", { token: WRITER, body: healBody() }), e)).status, 401);
  assert.equal((await worker.fetch(req("/v1/poll", { token: POLLER, body: { machineId: MID } }), e)).status, 401);
});
