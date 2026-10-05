// Pure heal-request inbox logic. No Cloudflare APIs here so it runs under node --test.
// State shape (per machine): { pending: {jti, exp}|null, seen: {jti: exp}, accepted: [unixSec,...] }

export const MAX_EXP_SEC = 120;
export const MIN_GAP_SEC = 300; // 1 accepted / 5 min / machine
export const MAX_PER_HOUR = 3;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEYS = ["v", "action", "machineId", "jti", "exp"];

export function emptyState() {
  return { pending: null, seen: {}, accepted: [] };
}

// Strict allow-list: exactly these five keys, nothing else.
export function validateBody(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return "body must be an object";
  const keys = Object.keys(body);
  if (keys.length !== KEYS.length || !KEYS.every((k) => keys.includes(k))) return "unexpected or missing fields";
  if (body.v !== 1) return "unsupported v";
  if (body.action !== "heal_request") return "unsupported action";
  if (typeof body.machineId !== "string" || !/^[A-Za-z0-9_.:-]{1,128}$/.test(body.machineId)) return "bad machineId";
  if (typeof body.jti !== "string" || !UUID_RE.test(body.jti)) return "bad jti";
  if (!Number.isInteger(body.exp)) return "bad exp";
  return null;
}

// Returns { status, error?, state }. `state` is the (possibly updated) state to persist.
export function accept(state, body, now) {
  const err = validateBody(body);
  if (err) return { status: 400, error: err, state };
  if (body.exp <= now) return { status: 400, error: "expired", state };
  if (body.exp > now + MAX_EXP_SEC) return { status: 400, error: "exp too far in future", state };

  const s = prune(state, now);
  if (s.seen[body.jti]) return { status: 409, error: "replayed jti", state: s };
  const last = s.accepted[s.accepted.length - 1];
  if (last !== undefined && now - last < MIN_GAP_SEC) return { status: 429, error: "rate limited", state: s };
  if (s.accepted.filter((t) => now - t < 3600).length >= MAX_PER_HOUR) return { status: 429, error: "hourly cap", state: s };

  s.seen[body.jti] = body.exp;
  // One pending flag (never stacks). Rate limit gap (300s) > max exp (120s), so a second accept cannot land while one is still pending.
  s.pending = { jti: body.jti, exp: body.exp };
  s.accepted.push(now);
  return { status: 202, state: s };
}

// Single-use consume. Expired flags are dropped, not returned.
export function consume(state, now) {
  const s = prune(state, now);
  const heal = !!(s.pending && s.pending.exp > now);
  s.pending = null;
  return { heal, state: s };
}

function prune(state, now) {
  const seen = {};
  // Keep jti until well past exp so a replay inside the window is always caught.
  for (const [j, exp] of Object.entries(state.seen)) if (exp + 3600 > now) seen[j] = exp;
  const pending = state.pending && state.pending.exp > now ? state.pending : null;
  return { pending, seen, accepted: state.accepted.filter((t) => now - t < 3600) };
}

export async function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(String(a))),
    crypto.subtle.digest("SHA-256", enc.encode(String(b))),
  ]);
  const x = new Uint8Array(ha), y = new Uint8Array(hb);
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}
