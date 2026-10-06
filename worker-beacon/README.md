# worker-beacon (heal-only inbox)

Cloudflare Worker for the **worker-beacon** mode in `docs/1.4.0/SELF-HEAL-MODES.md`.
It carries one message, `{v:1, action:"heal_request", machineId, jti, exp}`, and nothing else.
No shell, path, or log data crosses it. No account id and no secrets in git.

| Route | Auth | Result |
|---|---|---|
| `POST /v1/heal-request` | `Bearer WRITER_TOKEN` (box Grok Bot) | 202 stored; 400 bad schema/expired/`exp`>120s; 401; 403 unknown machine; 409 replayed `jti`; 429 over 1/5min or 3/hour |
| `POST /v1/poll` body `{"machineId":"..."}` | `Bearer POLLER_TOKEN` (Mac) | `{"heal":true\|false}`; true consumes the single pending flag |

Poll is a POST, not the GET in the spec, because it mutates (ack-on-read) and a retried GET must not eat a flag.
State lives in one Durable Object per machine so `jti` replay and rate limits are serialized.

## Status

Deployed and live on the operator's personal Cloudflare at https://latch-worker-beacon.kadosh.workers.dev. Tokens are set as Worker secrets and kept in a token file outside the repo, never in git. Prove C passed on the beacon path (`docs/1.4.0/PROVE-C-2026-10-05.md`).

## Deploy (operator, personal Cloudflare only)

Human step, not run from this repo. With Wrangler already signed in to the **personal Gmail** Cloudflare account:

    cd worker-beacon
    npx wrangler secret put WRITER_TOKEN
    npx wrangler secret put POLLER_TOKEN
    npx wrangler secret put ALLOWED_MACHINE_IDS   # comma list
    npx wrangler deploy

## Test

    npm test    # node --test, no Cloudflare needed

## Mac side

The optional poll hook lives in the heal script (one POST per 60s tick, then the `operator_request` heal path with reason `beacon_request`, disable file wins).

## Not done yet

Prove D (a real cloud disconnect while the heartbeat is moving). The live `.disable`-blocks-beacon check passed 2026-10-05 (`docs/1.4.0/PROVE-DISABLE-2026-10-05.md`).
