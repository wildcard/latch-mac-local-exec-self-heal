# worker-beacon (heal-only inbox)

Cloudflare Worker for the **worker-beacon** mode in `docs/1.4.0/SELF-HEAL-MODES.md`.
It carries one message, `{v:1, action:"heal_request", machineId, jti, exp}`, and nothing else.
No shell, path, or log data crosses it. Source only: no account id, no secrets, no deploy done from this repo.

| Route | Auth | Result |
|---|---|---|
| `POST /v1/heal-request` | `Bearer WRITER_TOKEN` (box Grok Bot) | 202 stored; 400 bad schema/expired/`exp`>120s; 401; 403 unknown machine; 409 replayed `jti`; 429 over 1/5min or 3/hour |
| `POST /v1/poll` body `{"machineId":"..."}` | `Bearer POLLER_TOKEN` (Mac) | `{"heal":true\|false}`; true consumes the single pending flag |

Poll is a POST, not the GET in the spec, because it mutates (ack-on-read) and a retried GET must not eat a flag.
State lives in one Durable Object per machine so `jti` replay and rate limits are serialized.

## Deploy (operator, personal Cloudflare only)

Not done by this change. With Wrangler already signed in to the **personal Gmail** Cloudflare account:

    cd worker-beacon
    npx wrangler secret put WRITER_TOKEN
    npx wrangler secret put POLLER_TOKEN
    npx wrangler secret put ALLOWED_MACHINE_IDS   # comma list
    npx wrangler deploy

## Test

    npm test    # node --test, no Cloudflare needed

## Not here yet

Mac poll client (one POST per 60s tick, then the `operator_request` heal path, disable file wins), and the S-NEW-D prove (plan C/D). `VERSION` stays 1.3.0.
