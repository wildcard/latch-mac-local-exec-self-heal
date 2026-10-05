// Latch worker-beacon: heal-only inbox. Carries one message type (heal_request) and nothing else.
//   POST /v1/heal-request   writer bearer  -> 202 | 400 | 401 | 403 | 409 | 429
//   POST /v1/poll           poller bearer  -> {"heal":true|false}  (consumes the pending flag)
// Secrets (wrangler secret put, never in git): WRITER_TOKEN, POLLER_TOKEN, ALLOWED_MACHINE_IDS (comma list).
import { accept, consume, emptyState, timingSafeEqual } from "./core.js";

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function bearerOk(request, secret) {
  const h = request.headers.get("authorization") || "";
  if (!secret || !h.startsWith("Bearer ")) return false;
  return timingSafeEqual(h.slice(7), secret);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return json({ error: "not found" }, 404);
    const isHeal = url.pathname === "/v1/heal-request";
    const isPoll = url.pathname === "/v1/poll";
    if (!isHeal && !isPoll) return json({ error: "not found" }, 404);

    if (!(await bearerOk(request, isHeal ? env.WRITER_TOKEN : env.POLLER_TOKEN))) return json({ error: "unauthorized" }, 401);

    let body;
    try { body = await request.json(); } catch { return json({ error: "invalid json" }, 400); }

    const allowed = String(env.ALLOWED_MACHINE_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
    const machineId = body && body.machineId;
    if (typeof machineId !== "string" || !allowed.includes(machineId)) {
      // Unknown machine: do not reveal which ids exist, store nothing.
      return json({ error: "machine not allowed" }, 403);
    }

    const stub = env.INBOX.get(env.INBOX.idFromName(machineId));
    return stub.fetch("https://inbox/" + (isHeal ? "accept" : "consume"), { method: "POST", body: JSON.stringify(body) });
  },
};

// One instance per machineId gives serialized, consistent state (jti replay + rate limit need that; KV would not).
export class Inbox {
  constructor(state) { this.state = state; }
  async fetch(request) {
    const op = new URL(request.url).pathname.slice(1);
    const now = Math.floor(Date.now() / 1000);
    const st = (await this.state.storage.get("s")) || emptyState();
    if (op === "accept") {
      const r = accept(st, await request.json(), now);
      await this.state.storage.put("s", r.state);
      return r.error ? json({ error: r.error }, r.status) : json({ ok: true }, r.status);
    }
    const r = consume(st, now);
    await this.state.storage.put("s", r.state);
    return json({ heal: r.heal });
  }
}
